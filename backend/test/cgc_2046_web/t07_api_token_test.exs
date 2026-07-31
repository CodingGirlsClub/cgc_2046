defmodule Cgc2046Web.T07ApiTokenTest do
  @moduledoc """
  T07 验收(HTTP 集成):ApiToken 签发/撤销 + /me"我能做什么"。

  对应 issue #8 验收点 1–5:
  1. 签发 token:绑定 workspace、能力域 scopes、有效期;只存 hash,明文不落库
  2. 撤销后立即全局失效(每请求白名单校验)
  3. 过期 token → 401
  4. token 绑定 workspace 与请求目标不一致 → 403
  5. /api/v1/me 返回身份、能力域、可执行 Step("我能做什么")
  """

  use Cgc2046Web.HttpCase, async: true

  import Ecto.Query

  alias Cgc2046.TestFixtures
  alias Cgc2046.Workspaces.ApiToken

  # ---------- 辅助 ----------

  defp member(ws, role_name) do
    user = TestFixtures.seed_user()
    TestFixtures.seed_membership(user, ws, roles: [role_name])
    user
  end

  defp role(ws, name) do
    Ash.read!(Cgc2046.Workspaces.Role, tenant: ws.id, authorize?: false)
    |> Enum.find(&(&1.name == name))
  end

  defp auth_conn(user) do
    build_conn() |> with_bearer_token(TestFixtures.seed_token(user))
  end

  defp issue(conn, ws, body) do
    post(conn, "/api/v1/workspaces/#{ws.id}/api_tokens", body)
  end

  defp revoke(conn, ws, token_id) do
    post(conn, "/api/v1/workspaces/#{ws.id}/api_tokens/#{token_id}/revoke", %{})
  end

  defp token_conn(plain_token) do
    build_conn() |> with_bearer_token(plain_token)
  end

  defp stored_token_hash?(token_id) do
    Repo.one(from t in "api_tokens", where: type(t.id, :string) == ^token_id, select: t.token_hash)
  end

  defp token_revoked_at(token_id) do
    Repo.one(from t in "api_tokens", where: type(t.id, :string) == ^token_id, select: t.revoked_at)
  end

  defp seed_step(ws, role_name, opts) do
    {:ok, wf} =
      Ash.create(Cgc2046.Workspaces.Workflow, %{name: Keyword.get(opts, :workflow_name, "wf")},
        tenant: ws.id,
        authorize?: false
      )

    {:ok, step} =
      Ash.create(
        Cgc2046.Workspaces.Step,
        %{title: Keyword.get(opts, :title, "s1"), position: Keyword.get(opts, :position, 1), workflow_id: wf.id},
        tenant: ws.id,
        authorize?: false
      )

    Ash.create!(Cgc2046.Workspaces.StepRole, %{step_id: step.id, role_id: role(ws, role_name).id},
      tenant: ws.id,
      authorize?: false
    )

    step
  end

  # ---------- 验收点 1: 签发(workspace/scopes/有效期;只存 hash) ----------

  describe "验收点1: 签发 token — 绑定 workspace、能力域 scopes、有效期;只存 hash" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws: ws}
    end

    test "workspace 成员签发 → 201,返回明文 + 绑定信息;库中只存 hash", %{owner: owner, ws: ws} do
      conn = auth_conn(owner) |> issue(ws, %{"name" => "opencly", "scopes" => ["read", "workflow:write"]})

      assert %{"token" => plain, "api_token" => api_token} = json_response(conn, 201)
      assert api_token["workspace_id"] == ws.id
      assert api_token["scopes"] == ["read", "workflow:write"]
      assert api_token["name"] == "opencly"
      assert api_token["expires_at"]

      # 明文只在响应中出现;库中只存 hash,且与明文 hash 一致
      stored_hash = stored_token_hash?(api_token["id"])
      refute stored_hash == plain
      assert stored_hash == ApiToken.hash_token(plain)
    end

    test "默认 scopes 为 read;默认有效期 30 天", %{owner: owner, ws: ws} do
      conn = auth_conn(owner) |> issue(ws, %{"name" => "default"})

      assert %{"api_token" => api_token} = json_response(conn, 201)
      assert api_token["scopes"] == ["read"]

      expires_at = DateTime.from_iso8601(api_token["expires_at"]) |> elem(1)
      assert DateTime.diff(expires_at, DateTime.utc_now(), :day) in [29, 30]
    end

    test "非法 scopes → 422;非成员签发 → 403", %{owner: owner, ws: ws} do
      conn = auth_conn(owner) |> issue(ws, %{"name" => "bad", "scopes" => ["admin:all"]})
      assert response(conn, 422)

      outsider = TestFixtures.seed_user()
      conn = auth_conn(outsider) |> issue(ws, %{"name" => "x"})
      assert response(conn, 403)
    end
  end

  # ---------- 验收点 2: 撤销后立即全局失效 ----------

  describe "验收点2: 撤销后立即全局失效(每请求白名单校验)" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws: ws}
    end

    test "撤销前 token 可访问 /me;撤销后同一 token 立即 401", %{owner: owner, ws: ws} do
      conn = auth_conn(owner) |> issue(ws, %{"name" => "revocable"})
      %{"token" => plain, "api_token" => api_token} = json_response(conn, 201)

      # 撤销前有效
      conn = token_conn(plain) |> get("/api/v1/me")
      assert json_response(conn, 200)["user"]["id"] == owner.id

      # 撤销 → 200,revoked_at 置位
      conn = auth_conn(owner) |> revoke(ws, api_token["id"])
      assert json_response(conn, 200)["api_token"]["revoked_at"]
      refute is_nil(token_revoked_at(api_token["id"]))

      # 撤销后同一明文 token 立即 401
      conn = token_conn(plain) |> get("/api/v1/me")
      assert response(conn, 401)
    end

    test "非属主撤销他人 token → 403", %{owner: owner, ws: ws} do
      other = member(ws, "Tutor")
      conn = auth_conn(owner) |> issue(ws, %{"name" => "mine"})
      %{"api_token" => api_token} = json_response(conn, 201)

      conn = auth_conn(other) |> revoke(ws, api_token["id"])
      assert response(conn, 403)
      assert is_nil(token_revoked_at(api_token["id"]))
    end
  end

  # ---------- 验收点 3: 过期 token → 401 ----------

  describe "验收点3: 过期 token → 401" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws: ws}
    end

    test "已过期 token 认证 → 401", %{owner: owner, ws: ws} do
      conn = auth_conn(owner) |> issue(ws, %{"name" => "short-lived", "expires_in_days" => 1})
      %{"token" => plain} = json_response(conn, 201)

      # 把 expires_at 改成过去,模拟过期
      Repo.update_all(
        from(t in "api_tokens", where: type(t.id, :string) != ^""),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)]
      )

      conn = token_conn(plain) |> get("/api/v1/me")
      assert response(conn, 401)
    end
  end

  # ---------- 验收点 4: token 绑定 workspace 与请求目标不一致 → 403 ----------

  describe "验收点4: token 绑定 workspace 与请求目标不一致 → 403" do
    setup do
      owner = TestFixtures.seed_user()
      ws_a = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      ws_b = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws_a: ws_a, ws_b: ws_b}
    end

    test "A 空间 token 请求 B 空间资源 → 403;B 空间内请求 → 200", %{owner: owner, ws_a: ws_a, ws_b: ws_b} do
      conn = auth_conn(owner) |> issue(ws_a, %{"name" => "a-only"})
      %{"token" => plain} = json_response(conn, 201)

      # /me 无 workspace 路径 → 放行(返回 token 绑定的 workspace_a)
      conn = token_conn(plain) |> get("/api/v1/me")
      assert json_response(conn, 200)["workspace_id"] == ws_a.id

      # 访问 B 空间资源(workspace 路径)→ 403
      conn = token_conn(plain) |> get("/api/v1/workspaces/#{ws_b.id}/profiles")
      assert response(conn, 403)

      # 访问 A 空间资源(workspace 路径一致)→ 放行(200)
      conn = token_conn(plain) |> get("/api/v1/workspaces/#{ws_a.id}/profiles")
      assert response(conn, 200)
    end
  end

  # ---------- 验收点 5: /me 返回身份、能力域、可执行 Step ----------

  describe "验收点5: /me 返回身份、能力域、可执行 Step" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws: ws}
    end

    test "JWT 会话保持占位(无绑定 workspace)", %{owner: owner} do
      conn = auth_conn(owner) |> get("/api/v1/me")
      body = json_response(conn, 200)
      assert body["user"]["id"] == owner.id
      assert body["workspace_id"] == nil
      assert body["roles"] == []
      assert body["scopes"] == []
      assert body["executable_steps"] == []
    end

    test "ApiToken 认证:返回身份 + 能力域 + 可执行 Step('我能做什么')", %{ws: ws} do
      tutor = member(ws, "Tutor")

      # Owner 创建 workflow + step(Tutor 可执行)+ step(Learner 可执行)
      seed_step(ws, "Tutor", title: "tutor-step", position: 1)
      seed_step(ws, "Learner", title: "learner-step", position: 2, workflow_name: "wf2")

      # Tutor 签发 token(含 workflow:write scopes)
      conn = auth_conn(tutor) |> issue(ws, %{"name" => "me", "scopes" => ["read", "workflow:write"]})
      %{"token" => plain} = json_response(conn, 201)

      conn = token_conn(plain) |> get("/api/v1/me")
      body = json_response(conn, 200)

      # 身份
      assert body["user"]["id"] == tutor.id
      # 能力域 = token scopes
      assert body["scopes"] == ["read", "workflow:write"]
      # workspace 绑定
      assert body["workspace_id"] == ws.id
      # 角色
      assert body["roles"] == ["Tutor"]
      # 可执行 Step:Tutor 角色只命中 tutor-step(交集非空)
      assert Enum.map(body["executable_steps"], & &1["title"]) == ["tutor-step"]
    end

    test "Learner token 只返回其可执行的 Step", %{ws: ws} do
      learner = member(ws, "Learner")
      seed_step(ws, "Tutor", title: "tutor-step", position: 1)
      seed_step(ws, "Learner", title: "learner-step", position: 2, workflow_name: "wf2")

      conn = auth_conn(learner) |> issue(ws, %{"name" => "learner-token"})
      %{"token" => plain} = json_response(conn, 201)

      conn = token_conn(plain) |> get("/api/v1/me")
      body = json_response(conn, 200)

      assert body["roles"] == ["Learner"]
      assert Enum.map(body["executable_steps"], & &1["title"]) == ["learner-step"]
    end
  end
end
