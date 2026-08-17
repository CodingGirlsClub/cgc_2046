defmodule Cgc2046.Mcp.Tools.SaveStepOutput do
  @moduledoc """
  写入 Step 产出（D7 写类，本期唯一写工具）。

  语义：把 `output` 合并进 `WorkflowRun.facts[step_key]`（浅合并，覆盖同 key）。
  授权：`StepAuthorization.authorize_signal/4`（owner/admin 豁免；其余按 StepRole 配置，
  未配置 = 不限制；读取失败 fail-closed）。

  E-7 #122 增量（学习 workflow 设计 §4.1/§4.2）：

  - 可选 `reason` 字段（D6-① variance）：随 `output` **同次浅合并**进
    `facts[step_key]["reason"]`；不传则不写该键（不覆盖既有值）。
  - 学员授权兜底：`authorize_signal/4` 拒绝时，若 actor 是该 learning run 锚定
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

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "save_step_output", fn actor, workspace_id, params ->
        run_id = params["run_id"] || params[:run_id]
        step_key = params["step_key"] || params[:step_key]
        output = params["output"] || params[:output] || %{}
        reason = params["reason"] || params[:reason]

        with {:ok, run} <- fetch_run(workspace_id, run_id),
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

  defp authorize(actor, workspace_id, run, step_key) do
    case StepAuthorization.authorize_signal(actor, workspace_id, run.definition_id, step_key) do
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
