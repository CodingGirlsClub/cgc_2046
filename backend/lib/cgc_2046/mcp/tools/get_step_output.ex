defmodule Cgc2046.Mcp.Tools.GetStepOutput do
  @moduledoc """
  读取某 Step 的产出（D7 读类）：WorkflowRun.facts 按 step_key 聚合的 key-value。
  schema 驱动渲染由前端负责，本工具只回原始 map（缺省字段不补）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")
    field(:run_id, {:required, :string}, description: "WorkflowRun ID（UUID）")
    field(:step_key, {:required, :string}, description: "步骤标识（如 outline_design）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_step_output", fn actor, workspace_id, params ->
        run_id = params["run_id"] || params[:run_id]
        step_key = params["step_key"] || params[:step_key]

        case Cgc2046.Workflows.WorkflowRun
             |> Ash.Query.for_read(:get_by_id, %{id: run_id})
             |> Ash.read_one(actor: actor, tenant: workspace_id) do
          {:ok, nil} ->
            {:error, "workflow run not found: #{run_id}"}

          {:ok, run} ->
            case Map.fetch(run.facts || %{}, step_key) do
              {:ok, output} ->
                {:ok, %{run_id: run.id, step_key: step_key, output: output}}

              :error ->
                {:error, "no output for step #{step_key} in run #{run_id}"}
            end

          {:error, %Ash.Error.Forbidden{}} ->
            {:error, "forbidden: no read access to workflow run #{run_id}"}

          {:error, _} ->
            {:error, "failed to load workflow run"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
