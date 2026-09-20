defmodule Cgc2046.Recruitment.ApplicationWorkflowInstantiator do
  @moduledoc """
  志愿者申请的 workflow run 实例化（U3；KTD1 申请行是状态权威、run 是执行镜像）。

  一个申请 = 一个 run：run 持**四个人工信号门控**（submitted / interview /
  training / assigned，manual-only 定义，无需 StepHandlerRegistry），逐段镜像
  R12 状态机：

  - create → start_run → waiting（submitted 门控，等初审）
  - 初审通过 → resume submitted → waiting（interview 门控）
  - 群面通过 → resume interview → waiting（training 门控）
  - 训练营完成·项目分配 → resume training + assigned → succeeded
    （R12 的 `training → assigned` 边承载「训练营完成」与「项目分配」两个事实，
    故一次流转放行 training/assigned 两个门控；assigned 为终态，run 同步终态，
    不留挂着 checkpoint 的长尾 run）
  - rejected → run failed；canceled → run cancelled（KTD1 段位流转动作侧）

  初审豁免（R8/AE11）：已 `assigned` 的申请人再申请新批次时，create 同事务内对
  首段门控（submitted）立即 `resume_signal`——run 与申请行一致地停在 interview
  门控，豁免事实落 run facts（`facts["initial_review"]`），且**不发初审结果通知**
  （该通知由「初次进入 interview 段」的业务信号承载，豁免路径不发）。

  定义按 workspace find_or_create（镜像 `SpeakerInvitationInstantiator`：
  同一 workspace 共用一份 published 定义），并发首建冲突（unique_name_version_
  per_workspace）重读既有定义，不打断申请创建。

  ## 实例键（run ↔ 申请的回溯）

  application 行无 workflow_run_id 列（U1 数据面；本单元不改 schema），run 经
  实例键 `input_snapshot["key"]` 回溯：`run_key/1` 是本单元的唯一单源，
  资源 action 与测试都经它取 run（`fetch_run/1`）。
  """

  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  require Ash.Query

  @definition_name "志愿者申请 workflow"
  @definition_type :recruitment_application

  # 四门控（顺序即 R12 段位链）
  @gate_keys ["submitted", "interview", "training", "assigned"]
  @initial_gate "submitted"

  @doc "run 实例键：run ↔ 申请行的唯一回溯键（写入 input_snapshot[\"key\"]）。"
  @spec run_key(String.t()) :: String.t()
  def run_key(application_id), do: "volunteer_application_#{application_id}"

  @doc """
  为申请创建并启动 workflow run（停在首门控 waiting）；初审豁免时同事务放行
  首段门控并写豁免事实。返回 `{:ok, run}` 或 `{:error, reason}`。

  调用方（VolunteerApplication.create 的 before_action）在同一事务内执行——
  失败回滚申请创建，不落孤儿 run。

  ## opts

  - `:exempt_initial_review?`（boolean，默认 false）：初审豁免（AE11）。
  - `:source_application_id`：豁免来源（既有 assigned 申请 id），仅写 facts。
  - `:cohort_id` / `:user_id`：随 input 快照落库（user_id 另被 WorkflowRun
    镜像进 `subject_user_id`，run 自描述的隐私/审计锚）。
  - `:actor`：resume_signal 的信号发起人（WorkflowRun action 要求认证 actor；
    豁免由系统判定，此处记为 create 事务内唯一在场的申请人）。
  """
  @spec start_run(String.t(), String.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def start_run(workspace_id, application_id, opts \\ []) do
    with {:ok, definition} <- ensure_definition(workspace_id),
         {:ok, run} <- create_and_start(workspace_id, definition, application_id, opts) do
      maybe_exempt_initial_review(run, opts)
    end
  end

  @doc """
  按实例键取申请的 run（资源 action 的段位流转读面）。

  返回 `{:ok, run}` | `{:error, :run_not_found}`。无 workflow_run_id 列，
  故经 `input_snapshot["key"]` 回溯（见 moduledoc）。
  """
  @spec fetch_run(String.t(), String.t()) :: {:ok, WorkflowRun.t()} | {:error, :run_not_found}
  def fetch_run(workspace_id, application_id) do
    WorkflowRun
    |> Ash.Query.filter(input_snapshot["key"] == ^run_key(application_id))
    |> Ash.read_one(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _ -> {:error, :run_not_found}
    end
  end

  # --- 实例化 ----------------------------------------------------------------

  defp create_and_start(workspace_id, definition, application_id, opts) do
    input =
      %{"volunteer_application_id" => application_id}
      |> put_optional("cohort_id", opts[:cohort_id])
      |> put_optional("user_id", opts[:user_id])

    case WorkflowRun.find_or_create_and_start(workspace_id, definition, input,
           key: run_key(application_id)
         ) do
      {:ok, run, _status} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_optional(input, _key, nil), do: input
  defp put_optional(input, key, value), do: Map.put(input, key, value)

  # 豁免（R8/AE11）：写豁免事实 → 放行首段门控（run 停在 interview 门控）。
  # 同事务严格语义：任一步失败回滚申请创建（豁免路径必须与申请状态一致，
  # 不留「status=interview 而 run 仍停在 submitted 门控」的漂移）。
  defp maybe_exempt_initial_review(run, opts) do
    if opts[:exempt_initial_review?] do
      with :ok <- put_exemption_fact(run, opts),
           {:ok, exempted_run} <- resume_gate(run, @initial_gate, exemption_payload(opts), opts) do
        {:ok, exempted_run}
      end
    else
      {:ok, run}
    end
  end

  defp exemption_payload(opts) do
    %{
      "gate" => @initial_gate,
      "exempted" => true,
      "reason" => "previous_assigned_application",
      "source_application_id" => opts[:source_application_id]
    }
  end

  # 豁免事实落 run facts（facts["initial_review"]）：申请行无豁免备注列（U1 数据面），
  # 申请侧的可见事实是 status 直入 interview，豁免原因/来源经 run facts 可回溯。
  defp put_exemption_fact(run, opts) do
    fact = %{
      "exempted" => true,
      "reason" => "previous_assigned_application",
      "source_application_id" => opts[:source_application_id]
    }

    facts = Map.put(run.facts || %{}, "initial_review", fact)

    case run
         |> Ash.Changeset.for_update(:update_facts_for_mcp, %{facts: facts},
           tenant: run.workspace_id,
           authorize?: false
         )
         |> Ash.update(tenant: run.workspace_id, authorize?: false) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, {:exemption_fact_failed, reason}}
    end
  end

  defp resume_gate(run, gate_key, payload, opts) do
    run
    |> Ash.Changeset.for_update(
      :resume_signal,
      %{"signal_type" => "workflow.#{gate_key}", "payload" => payload},
      actor: opts[:actor],
      tenant: run.workspace_id,
      authorize?: false
    )
    |> Ash.update(tenant: run.workspace_id, authorize?: false, actor: opts[:actor])
  end

  # --- 定义 find_or_create ----------------------------------------------------

  defp ensure_definition(workspace_id) do
    case fetch_definition(workspace_id) do
      {:ok, %WorkflowDefinition{} = definition} ->
        {:ok, definition}

      {:ok, nil} ->
        case create_definition(workspace_id) do
          {:ok, definition} ->
            {:ok, definition}

          # 并发首建：唯一索引冲突 → 重读既有定义（幂等）
          {:error, %Ash.Error.Invalid{}} ->
            case fetch_definition(workspace_id) do
              {:ok, %WorkflowDefinition{} = definition} -> {:ok, definition}
              _ -> {:error, :definition_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 取该租户已 published 的招募申请定义。多个时取最新（version desc，
  # inserted_at desc 兜底）——read_one 无排序时 Postgres 返回任意行
  # （SpeakerInvitationInstantiator.fetch_definition 同款纪律）。
  defp fetch_definition(workspace_id) do
    WorkflowDefinition
    |> Ash.Query.filter(type == @definition_type and status == :published)
    |> Ash.Query.sort(version: :desc, inserted_at: :desc)
    |> Ash.read_first(tenant: workspace_id, authorize?: false)
  end

  defp create_definition(workspace_id) do
    attrs = %{
      name: @definition_name,
      type: @definition_type,
      input_schema: %{},
      # 四段人工门控：段位推进一律由资源 action 的 resume_signal 放行（KTD1
      # v1 只用人工门控；自动步骤留二期）。
      node_def: %{
        "steps" => Enum.map(@gate_keys, &%{"id" => &1, "type" => "manual"})
      },
      approval_timeout: nil
    }

    with {:ok, draft} <-
           WorkflowDefinition
           |> Ash.Changeset.for_create(:create, attrs, tenant: workspace_id, authorize?: false)
           |> Ash.create(tenant: workspace_id, authorize?: false),
         {:ok, published} <-
           draft
           |> Ash.Changeset.for_update(:publish, %{}, tenant: workspace_id, authorize?: false)
           |> Ash.update(tenant: workspace_id, authorize?: false) do
      {:ok, published}
    end
  end
end
