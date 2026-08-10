defmodule Cgc2046Web.Plugs.PlatformAdminPlugTest do
  @moduledoc """
  PlatformAdminPlug 门控测试（Phase 1 / R1, R12 后端门控）：

  - current_user 为 platform_admin -> 放行
  - current_user 非 platform_admin -> 403
  - current_user 为 nil（未认证）-> 403
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046Web.Plugs.PlatformAdminPlug

  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp call(conn), do: PlatformAdminPlug.call(conn, PlatformAdminPlug.init([]))

  test "platform_admin 用户 -> 放行" do
    admin = platform_admin("padm-plug-ok@example.com")

    conn = build_conn() |> Plug.Conn.assign(:current_user, admin) |> call()

    refute conn.halted
    assert conn.status != 403
  end

  test "非 platform_admin 用户 -> 403" do
    user = register_user("padm-plug-regular@example.com")

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
