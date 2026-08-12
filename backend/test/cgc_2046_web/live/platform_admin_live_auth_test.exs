defmodule Cgc2046Web.Live.PlatformAdminLiveAuthTest do
  @moduledoc """
  /ops/admin LiveView 鉴权 on_mount 测试（P0 安全修复）。

  HTTP 层 PlatformAdminPlug 只挡首帧渲染；live_session 的 WebSocket 通道独立于
  HTTP pipeline，必须用 on_mount 在 mount 生命周期再校验——否则普通用户可经
  WebSocket 直连绕过门控浏览 Ash Admin 全部资源。

  覆盖：
  - session 无 current_user_id（未认证/被清）→ halt（不渲染）
  - session 有 non-admin user → halt
  - session 有 platform_admin user → cont（放行）
  - session_data/1：HTTP 层把已认证 current_user.id 存入 session
  """

  use Cgc2046Web.ConnCase, async: true

  import Plug.Conn

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046Web.Live.PlatformAdminLiveAuth

  defp socket do
    %Phoenix.LiveView.Socket{endpoint: Cgc2046Web.Endpoint, id: "test-socket"}
  end

  describe "on_mount/4 鉴权" do
    test "session 无 current_user_id（未认证）→ halt" do
      assert {:halt, _socket} =
               PlatformAdminLiveAuth.on_mount(:default, %{}, %{}, socket())
    end

    test "session 有 non-admin user → halt" do
      user = Fixtures.register_user("live-auth-regular")

      session = %{PlatformAdminLiveAuth.session_key() => user.id}

      assert {:halt, _socket} =
               PlatformAdminLiveAuth.on_mount(:default, %{}, session, socket())
    end

    test "session 有 platform_admin user → cont（放行）" do
      admin = Fixtures.platform_admin("live-auth-admin")

      session = %{PlatformAdminLiveAuth.session_key() => admin.id}

      assert {:cont, socket} =
               PlatformAdminLiveAuth.on_mount(:default, %{}, session, socket())

      assert socket.assigns.current_user.id == admin.id
    end
  end

  describe "session_data/1（HTTP 层注入 session）" do
    test "已认证 current_user → session 存 user id" do
      user = Fixtures.register_user("live-auth-session")

      conn = build_conn() |> assign(:current_user, user)
      key = PlatformAdminLiveAuth.session_key()

      assert PlatformAdminLiveAuth.session_data(conn) == %{key => user.id}
    end

    test "无 current_user → 空 session" do
      conn = build_conn()

      assert PlatformAdminLiveAuth.session_data(conn) == %{}
    end
  end
end
