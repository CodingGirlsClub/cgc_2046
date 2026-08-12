defmodule Cgc2046Web.Live.PlatformAdminLiveAuth do
  @moduledoc """
  /ops/admin（AshAdmin）LiveView 鉴权（P0 安全修复）。

  背景：HTTP 层 `:admin_browser` pipeline 末尾的 `PlatformAdminPlug` 只挡首帧渲染；
  `ash_admin/2` 宏内部用 `live_session`——其 WebSocket 通道独立于 HTTP pipeline，
  没有 `on_mount` 鉴权钩子时，普通用户可经 WebSocket 直连绕过门控浏览 Ash Admin
  全部资源（用户邮箱/工作流/邀请等）。

  修复（Phoenix LiveView auth 标准模式）：
  1. `session_data/1`：在 HTTP 层（live_session 首帧，auth pipeline 已认证且
     PlatformAdminPlug 已放行）把 `current_user.id` 写入 live session。
     Phoenix session 是签名的，攻击者无法伪造。
  2. `on_mount(:default, ...)`：mount 生命周期从 session 读 `current_user_id`，
     DB 重载 User 并校验 `is_platform_admin`——非 admin（含未认证/被 demote）
     一律 `{:halt, socket}` 阻止 PageLive mount（不渲染任何数据）。
     DB 重载而非信任 session 快照：用户被降级后即使持有旧 session 也不可访问。
  """

  require Logger

  import Phoenix.Component

  alias Cgc2046.Accounts.User
  alias Cgc2046.Policies.PlatformAdmin

  @session_key "cgc_current_user_id"

  @doc "live session 中当前用户 ID 的键（供测试/外部引用）"
  def session_key, do: @session_key

  @doc """
  HTTP 层 session 构建：把已认证 current_user 的 id 写入 live session。

  由 router `ash_admin("/admin", session: {__MODULE__, :session_data, []})`
  传入，`AshAdmin.Router.__session__/3` 在首帧 HTTP 请求（:admin_browser
  pipeline 已完成 AuthCookiePlug + load_from_bearer + PlatformAdminPlug）时执行。
  """
  def session_data(conn) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> %{@session_key => user_id}
      _ -> %{}
    end
  end

  @doc """
  LiveView mount 生命周期鉴权钩子。

  返回 `{:cont, socket}` 放行 / `{:halt, socket}` 阻止 mount。
  """
  def on_mount(_opts, _params, session, socket) do
    case session do
      %{@session_key => user_id} when is_binary(user_id) ->
        authorize_user(user_id, socket)

      _ ->
        {:halt, socket}
    end
  end

  defp authorize_user(user_id, socket) do
    case Ash.get(User, user_id, authorize?: false, domain: Cgc2046.GlobalApi) do
      {:ok, user} ->
        if PlatformAdmin.platform_admin?(user) do
          {:cont, assign(socket, :current_user, user)}
        else
          {:halt, socket}
        end

      {:error, error} ->
        # DB 故障等：fail-closed，不渲染 admin 内容（与 HTTP 层 403 同安全方向）
        Logger.error("[PlatformAdminLiveAuth] load user #{user_id} failed: #{inspect(error)}")

        {:halt, socket}
    end
  end
end
