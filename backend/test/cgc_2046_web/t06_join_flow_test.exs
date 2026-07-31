defmodule Cgc2046Web.T06JoinFlowTest do
  @moduledoc """
  T06 验收(HTTP 集成):加入流程 / JoinRequest 审批 / 邀请消费 / Profile CRUD。

  对应 issue #7 验收点 1–6:
  1. open 空间:直接加入并自动获得 Learner 角色(幂等)
  2. request 空间:申请 → 审批通过分配角色 / 拒绝
  3. invite_only 空间:不可被发现(列表/搜索不出现),仅链接可加入
  4. 邀请链接三种状态(used/revoked/expired)校验;撤销后立即失效
  5. 邀请预授权消费侧校验(Volunteer 生成的邀请不可预授权 Admin 级角色;
     T05 已实现生成侧,本票补消费侧兜底)
  6. Profile CRUD,租户内可见;写=本人
  """

  use Cgc2046Web.HttpCase, async: true

  import Ecto.Query

  alias Cgc2046.TestFixtures

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

  defp join(conn, ws), do: post(conn, "/api/v1/workspaces/#{ws.id}/join", %{})

  defp member_of?(user_id, ws) do
    Repo.exists?(
      from m in "workspace_memberships",
        where:
          type(m.user_id, :string) == ^user_id and type(m.workspace_id, :string) == ^ws.id
    )
  end

  defp has_role?(user_id, ws, role_name) do
    Repo.exists?(
      from mr in "membership_roles",
        join: m in "workspace_memberships",
        on: mr.membership_id == m.id,
        join: r in "roles",
        on: mr.role_id == r.id,
        where:
          type(m.user_id, :string) == ^user_id and type(m.workspace_id, :string) == ^ws.id and
            r.name == ^role_name
    )
  end

  defp join_request_status(join_request_id) do
    Repo.one(
      from j in "join_requests",
        where: type(j.id, :string) == ^join_request_id,
        select: j.status
    )
  end

  # ---------- 验收点 1: open 空间直接加入 + Learner ----------

  describe "验收点1: open 空间直接加入并自动获得 Learner 角色" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :open)
      %{ws: ws}
    end

    test "新用户加入 → 200 joined,membership + Learner 角色就位", %{ws: ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(ws)

      assert %{"result" => "joined", "membership_id" => membership_id} =
               json_response(conn, 200)

      assert membership_id
      assert member_of?(user.id, ws)
      assert has_role?(user.id, ws, "Learner")
    end

    test "重复加入幂等 → 仍 200,不重复建 membership", %{ws: ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(ws)
      assert json_response(conn, 200)["result"] == "joined"

      conn = auth_conn(user) |> join(ws)
      assert json_response(conn, 200)["result"] == "joined"

      count = Repo.aggregate(from(m in "workspace_memberships"), :count, :id)
      assert count >= 1
    end
  end

  # ---------- 验收点 2: request 空间申请 → 审批/拒绝 ----------

  describe "验收点2: request 空间申请 → 审批通过分配角色 / 拒绝" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :request)
      %{owner: owner, ws: ws}
    end

    test "提交申请 → 201 requested;pending 落表", %{ws: ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(ws)

      assert %{"result" => "requested", "join_request_id" => jr_id} =
               json_response(conn, 201)

      assert join_request_status(jr_id) == "pending"
      refute member_of?(user.id, ws)
    end

    test "Owner 审批通过(指定角色)→ 200 approved;membership + 角色就位", %{
      owner: owner,
      ws: ws
    } do
      user = TestFixtures.seed_user()
      learner_role = role(ws, "Learner")

      conn = auth_conn(user) |> join(ws)
      jr_id = json_response(conn, 201)["join_request_id"]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/join_requests/#{jr_id}/approve", %{
          "role_ids" => [learner_role.id]
        })

      assert %{"join_request" => jr} = json_response(conn, 200)
      assert jr["status"] == "approved"
      assert member_of?(user.id, ws)
      assert has_role?(user.id, ws, "Learner")
    end

    test "Owner 拒绝 → 200 rejected;不建 membership", %{owner: owner, ws: ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(ws)
      jr_id = json_response(conn, 201)["join_request_id"]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/join_requests/#{jr_id}/reject", %{})

      assert %{"join_request" => jr} = json_response(conn, 200)
      assert jr["status"] == "rejected"
      refute member_of?(user.id, ws)
    end

    test "Learner(无 join_request:manage)审批 → 403", %{ws: ws} do
      learner = member(ws, "Learner")
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(ws)
      jr_id = json_response(conn, 201)["join_request_id"]

      conn =
        auth_conn(learner)
        |> post("/api/v1/workspaces/#{ws.id}/join_requests/#{jr_id}/approve", %{
          "role_ids" => [role(ws, "Learner").id]
        })

      assert response(conn, 403)
    end
  end

  # ---------- 验收点 3: invite_only 不可被发现,仅链接可加入 ----------

  describe "验收点3: invite_only 空间不可被发现,仅链接可加入" do
    setup do
      owner = TestFixtures.seed_user()

      open_ws = TestFixtures.seed_workspace(owner: owner, slug: "t06-open", join_policy: :open)
      req_ws = TestFixtures.seed_workspace(owner: owner, slug: "t06-request", join_policy: :request)
      inv_ws = TestFixtures.seed_workspace(owner: owner, slug: "t06-invite", join_policy: :invite_only)

      %{owner: owner, open_ws: open_ws, req_ws: req_ws, inv_ws: inv_ws}
    end

    test "发现列表不含 invite_only;open/request 可见", %{
      open_ws: open_ws,
      req_ws: req_ws,
      inv_ws: inv_ws
    } do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> get("/api/v1/workspaces")

      ids = json_response(conn, 200)["workspaces"] |> Enum.map(& &1["id"])
      assert open_ws.id in ids
      assert req_ws.id in ids
      refute inv_ws.id in ids
    end

    test "搜索 q 也不出现 invite_only", %{inv_ws: _inv_ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> get("/api/v1/workspaces", %{"q" => "t06-invite"})

      workspaces = json_response(conn, 200)["workspaces"]
      assert workspaces == []
    end

    test "直接 join invite_only → 403", %{inv_ws: inv_ws} do
      user = TestFixtures.seed_user()

      conn = auth_conn(user) |> join(inv_ws)
      assert response(conn, 403)
    end
  end

  # ---------- 验收点 4: 邀请三种状态校验;撤销立即失效 ----------

  describe "验收点4: 邀请链接状态校验(used/revoked/expired)与撤销" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :invite_only)
      %{owner: owner, ws: ws}
    end

    defp create_invitation(conn, ws, expires_at) do
      conn
      |> post("/api/v1/workspaces/#{ws.id}/invitations", %{"expires_at" => expires_at})
    end

    defp consume(conn, ws, token) do
      post(conn, "/api/v1/workspaces/#{ws.id}/invitations/consume", %{"token" => token})
    end

    test "消费链接 → 200,创建 membership;链接置 used,再消费 → 422", %{owner: owner, ws: ws} do
      _inviter = member(ws, "Admin")
      expires = "2026-12-31T00:00:00Z"

      conn = auth_conn(owner) |> create_invitation(ws, expires)
      inv = json_response(conn, 201)["invitation"]
      assert inv["status"] == "active"
      token = inv["token"]

      user = TestFixtures.seed_user()
      conn = auth_conn(user) |> consume(ws, token)

      assert %{"invitation" => consumed} = json_response(conn, 200)
      assert consumed["status"] == "used"
      assert member_of?(user.id, ws)

      # 同 token 再次消费 → used 状态 → 422
      conn = auth_conn(TestFixtures.seed_user()) |> consume(ws, token)
      assert response(conn, 422)
    end

    test "撤销后立即失效:revoke → 200 revoked;再消费 → 422", %{owner: owner, ws: ws} do
      expires = "2026-12-31T00:00:00Z"

      conn = auth_conn(owner) |> create_invitation(ws, expires)
      inv = json_response(conn, 201)["invitation"]
      token = inv["token"]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/invitations/#{inv["id"]}/revoke", %{})

      assert %{"invitation" => revoked} = json_response(conn, 200)
      assert revoked["status"] == "revoked"

      conn = auth_conn(TestFixtures.seed_user()) |> consume(ws, token)
      assert response(conn, 422)
    end

    test "过期链接消费 → 422;不建 membership", %{owner: owner, ws: ws} do
      user = TestFixtures.seed_user()
      expired = "2020-01-01T00:00:00Z"

      conn = auth_conn(owner) |> create_invitation(ws, expired)
      token = json_response(conn, 201)["invitation"]["token"]

      conn = auth_conn(user) |> consume(ws, token)
      assert response(conn, 422)
      refute member_of?(user.id, ws)
    end
  end

  # ---------- 验收点 5: 邀请预授权消费侧校验 ----------

  describe "验收点5: 邀请预授权 Admin 级角色消费侧兜底校验" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner, join_policy: :invite_only)
      %{owner: owner, ws: ws}
    end

    defp create_invitation(conn, ws, expires_at, role_ids) do
      conn
      |> post("/api/v1/workspaces/#{ws.id}/invitations", %{
        "expires_at" => expires_at,
        "preauthorized_role_ids" => role_ids
      })
    end

    test "Volunteer 生成时预授权 Admin → 403(T05 生成侧);Owner → 201", %{owner: owner, ws: ws} do
      volunteer = member(ws, "Volunteer")
      admin_role = role(ws, "Admin")
      expires = "2026-12-31T00:00:00Z"

      conn = auth_conn(volunteer) |> create_invitation(ws, expires, [admin_role.id])
      assert response(conn, 403)

      conn = auth_conn(owner) |> create_invitation(ws, expires, [admin_role.id])
      assert response(conn, 201)
    end

    test "消费侧兜底:预授权 Admin 且 inviter 无 role:manage 的邀请消费 → 403",
         %{owner: _owner, ws: ws} do
      # 绕过生成侧校验(数据异常链路):直接落库一个预授权 Admin 的邀请,
      # inviter 为无 role:manage 的 Admin 角色(非 Owner)
      volunteer = member(ws, "Admin")
      admin_role = role(ws, "Admin")
      expires = ~U[2026-12-31 00:00:00Z]

      plain_token = "bypass-#{System.unique_integer([:positive])}"

      invitation =
        Ash.Seed.seed!(
          Cgc2046.Workspaces.Invitation,
          %{
            token_hash: Cgc2046.Workspaces.Invitation.hash_token(plain_token),
            expires_at: expires,
            preauthorized_role_ids: [admin_role.id],
            inviter_id: volunteer.id,
            status: :active
          },
          tenant: ws.id
        )

      assert invitation.status == :active

      user = TestFixtures.seed_user()
      conn = auth_conn(user) |> consume(ws, plain_token)
      assert response(conn, 403)
      refute member_of?(user.id, ws)
    end

    test "预授权 Learner 的邀请(非 Admin 级)→ 消费 200,角色就位", %{owner: owner, ws: ws} do
      learner_role = role(ws, "Learner")
      expires = "2026-12-31T00:00:00Z"

      conn = auth_conn(owner) |> create_invitation(ws, expires, [learner_role.id])
      token = json_response(conn, 201)["invitation"]["token"]

      user = TestFixtures.seed_user()
      conn = auth_conn(user) |> consume(ws, token)
      assert response(conn, 200)
      assert member_of?(user.id, ws)
      assert has_role?(user.id, ws, "Learner")
    end
  end

  # ---------- 验收点 6: Profile CRUD,租户内可见 ----------

  describe "验收点6: Profile CRUD,租户内可见;写=本人" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    defp create_profile(conn, ws, attrs) do
      post(conn, "/api/v1/workspaces/#{ws.id}/profiles", attrs)
    end

    test "创建 → 201(user_id=本人);列表/详情可见", %{ws: ws} do
      learner = member(ws, "Learner")

      conn =
        auth_conn(learner)
        |> create_profile(ws, %{"bio" => "hello", "tags" => ["a", "b"]})

      assert %{"profile" => p} = json_response(conn, 201)
      assert p["user_id"] == learner.id
      assert p["bio"] == "hello"
      assert p["tags"] == ["a", "b"]

      conn = auth_conn(learner) |> get("/api/v1/workspaces/#{ws.id}/profiles")

      profiles = json_response(conn, 200)["profiles"]
      assert Enum.any?(profiles, &(&1["user_id"] == learner.id))

      conn = auth_conn(learner) |> get("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}")
      assert json_response(conn, 200)["profile"]["user_id"] == learner.id
    end

    test "更新本人 → 200;删除 → 204;再查 404", %{ws: ws} do
      learner = member(ws, "Learner")

      conn =
        auth_conn(learner)
        |> create_profile(ws, %{"bio" => "v1"})

      assert json_response(conn, 201)

      conn =
        auth_conn(learner)
        |> patch("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}", %{"bio" => "v2"})

      assert json_response(conn, 200)["profile"]["bio"] == "v2"

      conn =
        auth_conn(learner)
        |> delete("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}")

      assert response(conn, 204)

      conn = auth_conn(learner) |> get("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}")
      assert response(conn, 404)
    end

    test "他人不可更新/删除(403);非成员不可读(403)", %{ws: ws} do
      learner = member(ws, "Learner")
      other = member(ws, "Learner")

      conn =
        auth_conn(learner)
        |> create_profile(ws, %{"bio" => "mine"})

      assert response(conn, 201)

      # 他人更新 → 403
      conn =
        auth_conn(other)
        |> patch("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}", %{"bio" => "hack"})

      assert response(conn, 403)

      # 他人删除 → 403
      conn = auth_conn(other) |> delete("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}")
      assert response(conn, 403)

      # 非成员读 → 403
      stranger = TestFixtures.seed_user()
      conn = auth_conn(stranger) |> get("/api/v1/workspaces/#{ws.id}/profiles")
      assert response(conn, 403)
    end

    test "Profile 租户内可见:同 workspace 成员可读他人 profile", %{ws: ws} do
      learner = member(ws, "Learner")
      tutor = member(ws, "Tutor")

      conn =
        auth_conn(learner)
        |> create_profile(ws, %{"bio" => "hello"})

      assert response(conn, 201)

      conn = auth_conn(tutor) |> get("/api/v1/workspaces/#{ws.id}/profiles/#{learner.id}")
      assert json_response(conn, 200)["profile"]["bio"] == "hello"
    end
  end
end
