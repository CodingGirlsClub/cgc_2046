defmodule Cgc2046.Mcp.Tools.SaveStepOutput do
  @moduledoc """
  写入 Step 产出（D7 写类，本期唯一写工具）。

  语义：把 `output` 合并进 `WorkflowRun.facts[step_key]`（浅合并，覆盖同 key）。
  授权：`StepAuthorization.authorize_signal/4`（owner/admin 豁免；其余按 StepRole 配置，
  未配置 = 不限制；读取失败 fail-closed）。

  终态保护：run 处于 cancelled/failed/succeeded 等终态时拒绝写入（返回 error），
  避免伪造状态流转——终态写入需求待切片 E workflow 演进再定。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Wrapper
  alias Cgc2046.Workflows.StepAuthorization

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:run_id, {:required, :string}, description: "WorkflowRun ID（UUID）")
    field(:step_key, {:required, :string}, description: "步骤标识")
    field(:output, {:required, :map}, description: "步骤产出（key-value，浅合并入 facts[step_key]）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "save_step_output", fn actor, workspace_id, params ->
        run_id = params["run_id"] || params[:run_id]
        step_key = params["step_key"] || params[:step_key]
        output = params["output"] || params[:output] || %{}

        with {:ok, run} <- fetch_run(actor, workspace_id, run_id),
             :ok <- authorize(actor, workspace_id, run, step_key),
             {:ok, updated} <- merge_facts(actor, workspace_id, run, step_key, output) do
          {:ok, %{run_id: updated.id, step_key: step_key, status: to_string(updated.status)}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp fetch_run(actor, workspace_id, run_id) do
    case Cgc2046.Workflows.WorkflowRun
         |> Ash.Query.for_read(:get_by_id, %{id: run_id})
         |> Ash.read_one(actor: actor, tenant: workspace_id) do
      {:ok, nil} -> {:error, "workflow run not found: #{run_id}"}
      {:ok, run} -> {:ok, run}
      {:error, %Ash.Error.Forbidden{}} -> {:error, "forbidden: no access to run #{run_id}"}
      {:error, _} -> {:error, "failed to load workflow run"}
    end
  end

  defp authorize(actor, workspace_id, run, step_key) do
    case StepAuthorization.authorize_signal(actor, workspace_id, run.definition_id, step_key) do
      :ok -> :ok
      {:error, reason} -> {:error, StepAuthorization.error_message(reason, step_key)}
    end
  end

  defp merge_facts(actor, workspace_id, run, step_key, output) do
    new_facts =
      Map.update(run.facts || %{}, step_key, output, fn existing ->
        Map.merge(existing || %{}, output)
      end)

    case run
         |> Ash.Changeset.for_update(
           :update_facts_for_mcp,
           %{facts: new_facts},
           actor: actor,
           tenant: workspace_id
         )
         |> Ash.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ash.Error.Invalid{} = err} -> {:error, Exception.message(err)}
      {:error, _} -> {:error, "failed to save step output"}
    end
  end
end
