defmodule Cgc2046Web.JoinRequestsController do
  @moduledoc """
  JoinRequest REST 端点(T06,spec §12)。

  - `GET /api/v1/workspaces/:workspace_id/join_requests` — 审批列表
    (需 `join_request:manage`,Owner/Admin)
  - `POST /api/v1/workspaces/:workspace_id/join_requests` — 提交申请
    (request 策略空间;已认证用户;可带 `requested_role_ids` 意向角色)
  - `POST /api/v1/workspaces/:workspace_id/join_requests/:id/approve`
    — 审批通过,body 指定 `role_ids`(审批方决定最终角色)
  - `POST /api/v1/workspaces/:workspace_id/join_requests/:id/reject`
    — 拒绝

  授权在资源 policy / action(approve/reject = `join_request:manage`),
  控制器只做错误契约翻译(§5)。
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.JoinRequest

  import Cgc2046Web.ApiHelpers

  def index(conn, _params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case Ash.read(JoinRequest, actor: actor, tenant: tenant) do
      {:ok, join_requests} ->
        conn
        |> put_status(200)
        |> json(%{join_requests: Enum.map(join_requests, &join_request_json/1)})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def create(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    requested_role_ids = params["requested_role_ids"]

    attrs =
      if requested_role_ids do
        %{requested_role_ids: requested_role_ids}
      else
        %{}
      end

    changeset = Ash.Changeset.for_create(JoinRequest, :create, attrs, actor: actor, tenant: tenant)

    handle_ash_result(conn, Ash.create(changeset), fn join_request ->
      conn
      |> put_status(201)
      |> json(%{join_request: join_request_json(join_request)})
    end)
  end

  def approve(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case Ash.get(JoinRequest, params["id"], actor: actor, tenant: tenant) do
      {:ok, join_request} ->
        changeset =
          Ash.Changeset.for_update(join_request, :approve, %{role_ids: params["role_ids"]},
            actor: actor,
            tenant: tenant
          )

        handle_ash_result(conn, Ash.update(changeset), fn jr ->
          conn
          |> put_status(200)
          |> json(%{join_request: join_request_json(jr)})
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def reject(conn, params) do
    actor = actor(conn)
    tenant = tenant(conn)

    case Ash.get(JoinRequest, params["id"], actor: actor, tenant: tenant) do
      {:ok, join_request} ->
        changeset =
          Ash.Changeset.for_update(join_request, :reject, %{},
            actor: actor,
            tenant: tenant
          )

        handle_ash_result(conn, Ash.update(changeset), fn jr ->
          conn
          |> put_status(200)
          |> json(%{join_request: join_request_json(jr)})
        end)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  defp join_request_json(jr) do
    %{
      id: jr.id,
      workspace_id: jr.workspace_id,
      user_id: jr.user_id,
      status: jr.status,
      requested_role_ids: jr.requested_role_ids,
      decided_by: jr.decided_by,
      decided_at: jr.decided_at,
      created_at: jr.inserted_at
    }
  end
end
