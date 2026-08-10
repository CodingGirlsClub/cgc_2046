defmodule Cgc2046Web.RouterTest do
  @moduledoc """
  /ops/admin（AshAdmin 挂载）门控测试（Phase 6 / R12）：

  - platform_admin GET /ops/admin -> 200（放行，AshAdmin dashboard 渲染）
  - 非 platform_admin GET /ops/admin -> 403（PlatformAdminPlug 拦截）
  - 未认证 GET /ops/admin -> 403

  门控由 :admin_browser pipeline 末尾的 PlatformAdminPlug 承担
  （不依赖 ash_admin 的 actor impersonation 机制）。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.User
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

  # 走真实 signIn GraphQL mutation 拿 cgc_token（与 graphql_profile_test 同源范式），
  # 保证 :admin_browser 的 AuthCookiePlug/load_from_bearer 全链路与生产一致。
  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{@password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  describe "GET /ops/admin (AshAdmin)" do
    test "platform_admin 可访问（200，dashboard 渲染）" do
      admin = platform_admin("router-admin-#{System.unique_integer([:positive])}@example.com")
      token = sign_in_token(admin.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin")

      assert conn.status == 200
    end

    test "非 platform_admin 被 403" do
      user = register_user("router-regular-#{System.unique_integer([:positive])}@example.com")
      token = sign_in_token(user.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin")

      assert conn.status == 403
    end

    test "未认证被 403" do
      conn = build_conn() |> get("/ops/admin")

      assert conn.status == 403
    end

    test "非 admin 访问子路径也被 403" do
      user = register_user("router-regular2-#{System.unique_integer([:positive])}@example.com")
      token = sign_in_token(user.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin/users")

      assert conn.status == 403
    end
  end
end
