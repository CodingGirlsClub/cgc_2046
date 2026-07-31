defmodule Cgc2046Web.StepsController do
  @moduledoc """
  Step 相关 REST 端点(T05):
  - `POST /api/v1/workspaces/:workspace_id/workflows/:workflow_id/steps`:创建 Step
    (需 `workflow:create`,与 Workflow 同权限)
  - `POST /api/v1/workspaces/:workspace_id/steps/:step_id/execute`:执行 Step
    (要求成员角色集 ∩ Step 允许角色集 交集非空,spec §4 / T05 验收 4)
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Step

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    attrs =
      params
      |> pick_attrs(["title", "position", "type", "agent_hint"])
      |> Map.put(:workflow_id, conn.path_params["workflow_id"])

    result =
      Ash.create(Step, attrs,
        actor: actor(conn),
        tenant: tenant(conn)
      )

    handle_ash_result(conn, result, fn step ->
      conn
      |> put_status(201)
      |> json(%{step: json_record(step, [:id, :title, :position, :type, :agent_hint, :workflow_id, :workspace_id, :inserted_at])})
    end)
  end

  def execute(conn, _params) do
    query =
      Step
      |> Ash.Query.for_read(:execute, %{step_id: conn.path_params["step_id"]},
        actor: actor(conn),
        tenant: tenant(conn)
      )

    result = Ash.read(query)

    handle_ash_result(conn, result, fn [step] ->
      json(conn, %{step: json_record(step, [:id, :title, :position, :type, :agent_hint, :workflow_id, :workspace_id]), executed: true})
    end)
  end
end
