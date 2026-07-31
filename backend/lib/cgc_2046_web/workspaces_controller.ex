defmodule Cgc2046Web.WorkspacesController do
  @moduledoc """
  `POST /api/v1/workspaces`:平台管理员创建 Workspace 并指定 Owner。

  授权在 Workspace 资源 policy(仅 `is_platform_admin` 可 create),控制器
  只负责把 Ash 错误翻译成平台错误契约状态码(见
  docs/spec-平台核心与OpenClacky对接.md §5):
  - 认证失败 → 401(RequireAuth 兜底)
  - 越权(Forbidden)→ 403
  - 校验失败/唯一性冲突(Invalid,含 slug 冲突)→ 422
  - 其它 → 400
  """

  use Cgc2046Web, :controller

  alias Cgc2046.Workspaces.Workspace

  def create(conn, params) do
    actor = conn.assigns[:current_user]

    case Ash.create(Workspace, workspace_attrs(params), actor: actor) do
      {:ok, workspace} ->
        conn
        |> put_status(201)
        |> json(%{workspace: workspace_json(workspace)})

      {:error, %Ash.Error.Forbidden{}} ->
        send_error(conn, 403, "Forbidden")

      {:error, %Ash.Error.Invalid{}} ->
        send_error(conn, 422, "Invalid")

      {:error, error} ->
        send_error(conn, 400, Exception.message(error))
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

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
