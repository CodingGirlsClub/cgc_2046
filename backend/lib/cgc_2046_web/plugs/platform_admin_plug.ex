defmodule Cgc2046Web.Plugs.PlatformAdminPlug do
  @moduledoc """
  平台管理员门控 plug（Phase 1 / R1, R12 后端门控）。

  从 `conn.assigns[:current_user]` 读 `is_platform_admin`，为 `true` 时放行，
  否则返回 403（覆盖 false / nil / 未 assign 三种情况）。

  放在 `:admin_browser` pipeline 末尾（`load_actor` 之后），
  确保 `/ops/admin` 及未来 `/admin` 浏览器路由仅 platform_admin 可达。
  不依赖 ash_admin 的 actor 机制（那是 impersonation，非认证）。
  """

  @behaviour Plug

  import Plug.Conn

  alias Cgc2046.Accounts.Policies.PlatformAdmin

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if PlatformAdmin.platform_admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end
end
