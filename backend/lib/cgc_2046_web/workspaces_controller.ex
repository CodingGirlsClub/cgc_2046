defmodule Cgc2046Web.WorkspacesController do
  @moduledoc """
  Workspace REST 端点。

  - `GET /api/v1/workspaces` — 公开发现列表(T06):仅 open/request 空间
    可被发现(`discover` action 过滤 invite_only),支持 `?q=` 搜索
  - `POST /api/v1/workspaces` — 平台管理员创建 Workspace 并指定 Owner
  - `POST /api/v1/workspaces/:workspace_id/join` — 加入流程(T06):
    open 直接加入得 Learner / request 提交申请 / invite_only 拒绝(仅链接)

  授权在资源 policy / action / 服务内(见 spec §4、§12):
  - 创建 = 仅平台管理员(Workspace policy)
  - 发现列表/加入 = 任何已认证用户(open/request 对公众开放)
  - 控制器只负责把 Ash 错误翻译成平台错误契约状态码(§5)
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Workspace

  import Cgc2046Web.ApiHelpers

  def index(conn, params) do
    actor = conn.assigns[:current_user]
    q = params["q"]

    query =
      Ash.Query.for_read(Workspace, :discover, %{}, actor: actor)

    query =
      if q && q != "" do
        import Ash.Query, only: [filter: 2]

        filter(query, contains(slug, ^q) or contains(name, ^q))
      else
        query
      end

    case Ash.read(query) do
      {:ok, workspaces} ->
        conn
        |> put_status(200)
        |> json(%{workspaces: Enum.map(workspaces, &workspace_json/1)})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def create(conn, params) do
    actor = conn.assigns[:current_user]

    case Ash.create(Workspace, workspace_attrs(params), actor: actor) do
      {:ok, workspace} ->
        conn
        |> put_status(201)
        |> json(%{workspace: workspace_json(workspace)})

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  def join(conn, _params) do
    actor = conn.assigns[:current_user]
    workspace_id = tenant(conn)

    case Ash.get(Workspace, workspace_id, actor: actor) do
      {:ok, workspace} ->
        do_join(conn, workspace, actor)

      {:error, error} ->
        handle_ash_result(conn, {:error, error}, fn _ -> :ok end)
    end
  end

  defp do_join(conn, workspace, actor) do
    case Cgc2046.Join.join_open(workspace, actor) do
      {:ok, membership} ->
        conn
        |> put_status(200)
        |> json(%{result: "joined", membership_id: membership.id})

      {:error, :not_open} ->
        case Cgc2046.Join.submit_request(workspace, actor) do
          {:ok, join_request} ->
            conn
            |> put_status(201)
            |> json(%{result: "requested", join_request_id: join_request.id})

          {:error, :not_request} ->
            send_error(conn, 403, "invite_only workspace is not joinable directly")

          {:error, %Ash.Error.Invalid{} = _error} ->
            send_error(conn, 422, "Invalid")

          {:error, %Ash.Error.Forbidden{} = _error} ->
            send_error(conn, 403, "Forbidden")

          {:error, error} ->
            send_error(conn, 400, "Join failed: #{inspect(error)}")
        end
    end
  end

  defp workspace_attrs(params) do
    params
    |> Map.take(["slug", "name", "join_policy", "owner_id"])
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp workspace_json(workspace) do
    %{
      id: workspace.id,
      slug: workspace.slug,
      name: workspace.name,
      join_policy: workspace.join_policy,
      owner_id: workspace.owner_id
    }
  end
end
