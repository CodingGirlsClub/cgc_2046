defmodule Cgc2046Web.MeTest do
  @moduledoc """
  T02 切片C:REST `GET /api/v1/me` 认证语义。

  对应验收标准:
  - 无 token / 错误 token → 401
  - 已撤销 token → 401(白名单模式生效)
  - 有效 Bearer 请求可取得当前用户 → 200

  响应形状与 T18 平台接口清单对齐:`{user:{id,email}, workspace_id,
  roles, scopes}`(workspace/roles/scopes 由 T03/T04 填充,T02 返回占位)。
  """

  use Cgc2046Web.HttpCase, async: true

  alias Cgc2046.TestFixtures

  describe "GET /api/v1/me" do
    test "无 token → 401" do
      conn = get(build_conn(), "/api/v1/me")
      assert response(conn, 401)
    end

    test "错误 token → 401" do
      conn =
        build_conn()
        |> with_bearer_token("definitely-not-a-real-token")
        |> get("/api/v1/me")

      assert response(conn, 401)
    end

    test "有效 token → 200 返回当前用户" do
      user = TestFixtures.seed_user()
      token = TestFixtures.seed_token(user)

      conn =
        build_conn()
        |> with_bearer_token(token)
        |> get("/api/v1/me")

      body = json_response(conn, 200)

      assert body["user"]["id"] == user.id
      assert body["user"]["email"] == to_string(user.email)
      assert body["workspace_id"] == nil
      assert body["roles"] == []
      assert body["scopes"] == []
    end

    test "已撤销 token → 401(白名单模式生效)" do
      user = TestFixtures.seed_user()
      token = TestFixtures.seed_token(user)

      assert :ok = AshAuthentication.TokenResource.revoke(Cgc2046.Accounts.Token, token)

      conn =
        build_conn()
        |> with_bearer_token(token)
        |> get("/api/v1/me")

      assert response(conn, 401)
    end
  end
end
