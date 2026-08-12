defmodule Cgc2046Web.Plugs.PlatformAdminPlugTest do
  @moduledoc """
  PlatformAdminPlug 门控测试（Phase 1 / R1, R12 后端门控）：

  - current_user 为 platform_admin -> 放行
  - current_user 非 platform_admin -> 403
  - current_user 为 nil（未认证）-> 403
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046Web.Plugs.PlatformAdminPlug

  defp call(conn), do: PlatformAdminPlug.call(conn, PlatformAdminPlug.init([]))

  test "platform_admin 用户 -> 放行" do
    admin = Fixtures.platform_admin("padm-plug-ok")

    conn = build_conn() |> Plug.Conn.assign(:current_user, admin) |> call()

    refute conn.halted
    assert conn.status != 403
  end

  test "非 platform_admin 用户 -> 403" do
    user = Fixtures.register_user("padm-plug-regular")

    conn = build_conn() |> Plug.Conn.assign(:current_user, user) |> call()

    assert conn.halted
    assert conn.status == 403
  end

  test "current_user 为 nil（未认证）-> 403" do
    conn = build_conn() |> Plug.Conn.assign(:current_user, nil) |> call()

    assert conn.halted
    assert conn.status == 403
  end

  test "current_user 未 assign -> 403" do
    conn = build_conn() |> call()

    assert conn.halted
    assert conn.status == 403
  end
end
