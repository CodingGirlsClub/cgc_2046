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

  alias Cgc2046.AccountsFixtures, as: Fixtures

  # 走真实 signIn GraphQL mutation 拿 cgc_token（与 graphql_profile_test 同源范式），
  # 保证 :admin_browser 的 AuthCookiePlug/load_from_bearer 全链路与生产一致。
  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{Fixtures.password()}") {
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
      admin = Fixtures.platform_admin("router-admin")
      token = sign_in_token(admin.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin")

      assert conn.status == 200
    end

    test "非 platform_admin 被 403" do
      user = Fixtures.register_user("router-regular")
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
      user = Fixtures.register_user("router-regular2")
      token = sign_in_token(user.email)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/ops/admin/users")

      assert conn.status == 403
    end
  end
end
