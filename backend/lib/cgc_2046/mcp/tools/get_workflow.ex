defmodule Cgc2046.Mcp.Tools.GetWorkflow do
  @moduledoc """
  读取 WorkflowRun 状态（D7 读类）：status / facts keys / 时间线字段。
  只读展示形态（形态 X：不含执行操作）。
  """
  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台成员可读：读取一个工作流（run_id）的状态。返回 run_id /
    status / definition_id / definition_version / step_keys_with_facts（已有产出的步骤名，排序）/
    started_at / finished_at。只读，不能通过本工具推进或操作工作流；逐步产出用 get_step_output 读。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:run_id, {:required, :string}, description: "WorkflowRun ID（UUID）")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "get_workflow", fn actor, workspace_id, params ->
        run_id = params["run_id"]

        case Cgc2046.Workflows.WorkflowRun
             |> Ash.Query.for_read(:get_by_id, %{id: run_id})
             |> Ash.read_one(actor: actor, tenant: workspace_id) do
          {:ok, nil} ->
            {:error, "workflow run not found: #{run_id}"}

          {:ok, run} ->
            {:ok,
             %{
               run_id: run.id,
               status: to_string(run.status),
               definition_id: run.definition_id,
               definition_version: run.definition_version,
               step_keys_with_facts: run.facts |> Map.keys() |> Enum.sort(),
               started_at: run.started_at,
               finished_at: run.finished_at
             }}

          {:error, %Ash.Error.Forbidden{}} ->
            {:error, "forbidden: no read access to workflow run #{run_id}"}

          {:error, _} ->
            {:error, "failed to load workflow run"}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end
end
