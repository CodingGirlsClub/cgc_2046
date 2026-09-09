defmodule Cgc2046.Mcp.Tools.SaveStepOutput do
  @moduledoc """
  写入 Step 产出（D7 写类，本期唯一写工具）。

  语义：把 `output` 合并进 `WorkflowRun.facts[step_key]`（浅合并，覆盖同 key）。
  授权：`StepAuthorization.authorize_write/4`（owner/admin 豁免；其余按 StepRole
  配置，Step 行存在但未配置 = 不限制；**未知 step_key（Step 行不存在）
  fail-closed**；读取失败 fail-closed）。

  P1 安全修复（2026-09-09 外部安全评审）：

  - facts 顶层治理保留 key（`@reserved_fact_keys`）一律拒绝写入——通用入口
    曾可篡改 `prep_policy_override`（关闭人工审核、降低质量阈值）等策略/
    治理语义字段，绕过专用工具的权限与前置断言后走正常质量报告流程发布；
    保留 key 只能由专用工具/资源 action 写。
  - 未知 step_key 收紧为 fail-closed（原「不存在的 Step = 不限制」是漏洞
    根因之一：资源层仅查成员身份，工具层授权是唯一防线）。

  E-7 #122 增量（学习 workflow 设计 §4.1/§4.2）：

  - 可选 `reason` 字段（D6-① variance）：随 `output` **同次浅合并**进
    `facts[step_key]["reason"]`；不传则不写该键（不覆盖既有值）。
  - 学员授权兜底：`authorize_write/4` 拒绝时，若 actor 是该 learning run 锚定
    Enrollment 的报名学员本人（`StepAuthorization.enrolled_learner?/3`），放行——
    学习执行在学员侧 BYO，学员必须能写自己的进度账本。资源层 bypass
    （`ActorIsEnrolledLearner`）与此共用同一条判定规则。
  - run 读取不带 actor：学员（非成员）读不到自己的 learning run 会导致工具层
    提前 404；改为 `authorize?: false` 读取 + 显式授权判定（fetch 后
    authorize/merge 仍为真实门禁，语义不变）。

  终态保护：run 处于 cancelled/failed/succeeded 等终态时拒绝写入（返回 error），
  避免伪造状态流转——终态写入需求待切片 E workflow 演进再定。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.StepAuthorization

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:run_id, {:required, :string}, description: "WorkflowRun ID（UUID）")
    field(:step_key, {:required, :string}, description: "步骤标识")
    field(:output, {:required, :map}, description: "步骤产出（key-value，浅合并入 facts[step_key]）")

    field(:reason, :string,
      description: "可选：本次写入理由（variance，D6-①）；随 output 同次浅合并进 facts[step_key]"
    )
  end

  # P1 安全修复（2026-09-09 外部安全评审）：facts 顶层治理/策略语义保留 key。
  # 取证 = backend/lib 全量 facts 顶层 key 读写点（grep `facts["…"]` / `Map.get(facts, …)`）：
  #
  # - 教研状态机/策略/指派（Curriculum.Prep 消费，专用工具写）：prep_state
  #   （require_state 门禁）、prep_policy_override（policy/1 override-first
  #   合并 → update_prep_policy）、assignee_user_id（assignee/1 → claim/assign_prep_tutor）；
  # - 质量/审核/发布链（专用工具写，投影或前置锚消费）：latest_quality_report、
  #   below_threshold_pending（override_prep_gate 前置锚）、change_requests、
  #   gate_violations、gate_passed_at、gate_checked_draft_version、gate_override、
  #   approved_by、approved_at、published_at、published_by、
  #   published_revision_id、published_revision_number；
  # - 其他域：materials（SpeakerInvitation ensure_materials_produced 前置，
  #   save_materials action 写）、issues（save_course_content KTD1 镜像写）。
  #
  # 新增 facts 顶层治理 key 时同步本清单。
  @reserved_fact_keys MapSet.new(~w(
    prep_state prep_policy_override assignee_user_id
    latest_quality_report below_threshold_pending change_requests
    gate_violations gate_passed_at gate_checked_draft_version gate_override
    approved_by approved_at
    published_at published_by published_revision_id published_revision_number
    materials issues
  ))

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "save_step_output", fn actor, workspace_id, params ->
        run_id = params["run_id"]
        step_key = params["step_key"]
        output = params["output"] || %{}
        reason = params["reason"]

        with :ok <- require_writable_key(step_key),
             {:ok, run} <- fetch_run(workspace_id, run_id),
             :ok <- authorize(actor, workspace_id, run, step_key),
             {:ok, updated} <- merge_facts(actor, workspace_id, run, step_key, output, reason) do
          {:ok, %{run_id: updated.id, step_key: step_key, status: to_string(updated.status)}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # 学员（非成员）读不到自己的 learning run（read policy 仅成员/平台管理员）；
  # 工具层改为不带 actor 读取，授权由后续 authorize + Ash update（资源层 policy）
  # 双重判定兜底——读取本身不再充当门禁。
  defp fetch_run(workspace_id, run_id) do
    case Cgc2046.Workflows.WorkflowRun
         |> Ash.Query.for_read(:get_by_id, %{id: run_id})
         |> Ash.read_one(authorize?: false, tenant: workspace_id) do
      {:ok, nil} -> {:error, "workflow run not found: #{run_id}"}
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:error, "failed to load workflow run"}
    end
  end

  # 保留 key 只能由专用策略/治理工具写入（@reserved_fact_keys）；通用入口一律
  # 拒绝——先于 run 读取与授权判定（对 owner/admin 豁免与学员豁免同样生效）。
  defp require_writable_key(step_key) do
    if MapSet.member?(@reserved_fact_keys, step_key) do
      {:error, "reserved fact key #{step_key} is managed by a dedicated tool"}
    else
      :ok
    end
  end

  defp authorize(actor, workspace_id, run, step_key) do
    case StepAuthorization.authorize_write(actor, workspace_id, run.definition_id, step_key) do
      :ok ->
        :ok

      {:error, reason} ->
        # E-7 #122：StepRole 不命中时，学习 run 放行报名学员本人（设计 §4.1）
        if StepAuthorization.enrolled_learner?(actor, workspace_id, run) do
          :ok
        else
          {:error, StepAuthorization.error_message(reason, step_key)}
        end
    end
  end

  defp merge_facts(actor, workspace_id, run, step_key, output, reason) do
    # reason 随 output 同次浅合并（D6-①：variance 与产出同事务落账本）；
    # 无 reason 不写该键（不覆盖既有值）。
    step_payload =
      case reason do
        r when is_binary(r) and r != "" -> Map.merge(output, %{"reason" => r})
        _ -> output
      end

    new_facts =
      Map.update(run.facts || %{}, step_key, step_payload, fn existing ->
        Map.merge(existing || %{}, step_payload)
      end)

    case run
         |> Ash.Changeset.for_update(
           :update_facts_for_mcp,
           %{facts: new_facts},
           actor: actor,
           tenant: workspace_id
         )
         |> Ash.update() do
      {:ok, updated} ->
        {:ok, updated}

      # 资源层 policy 拒绝（非成员且非学员）→ 与工具层拒绝同语义，对外统一口径
      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: not authorized to write run #{run.id}"}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      {:error, _} ->
        {:error, "failed to save step output"}
    end
  end
end
