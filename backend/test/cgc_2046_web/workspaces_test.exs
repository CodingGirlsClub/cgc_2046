defmodule Cgc2046Web.WorkspacesTest do
  @moduledoc """
  T03 切片A:REST `POST /api/v1/workspaces` 创建 Workspace 的授权语义。

  对应验收标准:
  - 平台管理员可创建 Workspace 并指定 Owner → 201
  - 非平台管理员创建 → 403
  - 未认证 → 401(require_auth 兜底)
  - slug 冲突 → 422

  错误契约见 docs/spec-平台核心与OpenClacky对接.md §5:
  401 认证失败 / 403 越权 / 409 冲突 / 422 校验失败,body `{"error": "..."}`。
  """

  use Cgc2046Web.HttpCase, async: true

  alias Cgc2046.TestFixtures

  describe "POST /api/v1/workspaces" do
    test "平台管理员创建 Workspace 并指定 Owner → 201" do
      admin = TestFixtures.seed_platform_admin()
      owner = TestFixtures.seed_user()
      token = TestFixtures.seed_token(admin)

      conn =
        build_conn()
        |> with_bearer_token(token)
        |> post("/api/v1/workspaces", %{
          "slug" => "club-alpha",
          "name" => "Club Alpha",
          "join_policy" => "request",
          "owner_id" => owner.id
        })

      body = json_response(conn, 201)

      assert body["workspace"]["slug"] == "club-alpha"
      assert body["workspace"]["name"] == "Club Alpha"
      assert body["workspace"]["join_policy"] == "request"
      assert body["workspace"]["owner_id"] == owner.id
      assert body["workspace"]["id"]
    end

    test "非平台管理员创建 → 403" do
      user = TestFixtures.seed_user()
      owner = TestFixtures.seed_user()
      token = TestFixtures.seed_token(user)

      conn =
        build_conn()
        |> with_bearer_token(token)
        |> post("/api/v1/workspaces", %{
          "slug" => "club-beta",
          "name" => "Club Beta",
          "join_policy" => "request",
          "owner_id" => owner.id
        })

      assert response(conn, 403)
    end

    test "未认证创建 → 401" do
      conn =
        post(build_conn(), "/api/v1/workspaces", %{
          "slug" => "club-gamma",
          "name" => "Club Gamma",
          "join_policy" => "request",
          "owner_id" => Ecto.UUID.generate()
        })

      assert response(conn, 401)
    end

    test "slug 冲突 → 422" do
      admin = TestFixtures.seed_platform_admin()
      token = TestFixtures.seed_token(admin)

      payload = %{
        "slug" => "club-delta",
        "name" => "Club Delta",
        "join_policy" => "request",
        "owner_id" => admin.id
      }

      conn1 = build_conn() |> with_bearer_token(token) |> post("/api/v1/workspaces", payload)
      assert response(conn1, 201)

      conn2 = build_conn() |> with_bearer_token(token) |> post("/api/v1/workspaces", payload)
      assert response(conn2, 422)
    end
  end
end
