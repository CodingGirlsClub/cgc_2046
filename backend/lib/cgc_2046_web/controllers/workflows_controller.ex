defmodule Cgc2046Web.WorkflowsController do
  @moduledoc """
  `POST /api/v1/workspaces/:workspace_id/workflows`:部署 Workflow DSL(租户内,T08)。

  授权:`workflow:deploy`(Owner/Admin/Tutor,spec §4)—— 由 Deploy 编排显式
  校验;DSL 非法(step 顺序乱 / allowed_roles 不存在 / type 非法)→ 422;
  无部署权限 → 403。幂等:同 name+workspace 已存在 → 更新(200),否则创建(201)。

  `POST /api/v1/workspaces/:workspace_id/workflows/:id/archive`:归档 Workflow
  (status → archived,需 `workflow:create`);归档后 Step 不可执行。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Workflow
  alias Cgc2046.Workflows.Deploy

  import Cgc2046Web.ApiHelpers

  def create(conn, params) do
    case Deploy.deploy(actor(conn), tenant(conn), params) do
      {:ok, workflow, :created} ->
        conn
        |> put_status(201)
        |> json(%{workflow: json_record(workflow, [:id, :name, :description, :dsl_version, :status, :workspace_id, :inserted_at])})

      {:ok, workflow, :updated} ->
        conn
        |> put_status(200)
        |> json(%{workflow: json_record(workflow, [:id, :name, :description, :dsl_version, :status, :workspace_id, :inserted_at])})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def archive(conn, params) do
    workflow =
      Ash.get(Workflow, params["id"],
        actor: actor(conn),
        tenant: tenant(conn)
      )

    case workflow do
      {:ok, workflow} ->
        result =
          Ash.update(workflow, %{},
            actor: actor(conn),
            tenant: tenant(conn),
            action: :archive
          )

        handle_ash_result(conn, result, fn wf ->
          json(conn, %{workflow: json_record(wf, [:id, :name, :status, :workspace_id, :updated_at])})
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end
end
