defmodule Cgc2046Web.MeController do
  @moduledoc """
  `GET /api/v1/me`:返回当前认证用户。

  响应形状与 T18 平台接口清单对齐:
  `%{user: %{id, email}, workspace_id, roles, scopes}`。
  workspace_id/roles/scopes 由 T03/T04(Workspace 与多租户、成员与角色)
  填充;T02 返回占位。
  """

  use Cgc2046Web, :controller

  def show(conn, _params) do
    user = conn.assigns[:current_user]

    json(conn, %{
      user: %{id: user.id, email: user.email},
      workspace_id: nil,
      roles: [],
      scopes: []
    })
  end
end
