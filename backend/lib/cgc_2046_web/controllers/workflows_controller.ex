defmodule Cgc2046Web.WorkflowsController do
  @moduledoc """
  `POST /api/v1/workspaces/:workspace_id/workflows`:创建 Workflow(租户内)。

  授权:`workflow:create`(Owner/Admin/Tutor,spec §4)—— 由 Workflow 资源
  policy + 写 action 首行 `Rbac.ensure!` 双重把关,控制器只翻译状态码。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Workflow

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    attrs = pick_attrs(params, ["name", "description", "dsl_version"])

    result =
      Ash.create(Workflow, attrs,
        actor: actor(conn),
        tenant: tenant(conn)
      )

    handle_ash_result(conn, result, fn workflow ->
      conn
      |> put_status(201)
      |> json(%{workflow: json_record(workflow, [:id, :name, :description, :dsl_version, :workspace_id, :inserted_at])})
    end)
  end
end
