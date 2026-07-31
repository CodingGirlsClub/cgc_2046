defmodule Cgc2046Web.T05PermissionMatrixTest do
  @moduledoc """
  T05 验收(HTTP 集成):权限矩阵逐操作判定 / 审计落表 / 审计查询隔离 / Step 执行交集。

  对应 issue #6 验收点 1–4。越权语义:
  - 公共资源(Workflow/邀请)越权 → **403**
  - Step 执行交集空 → **403**(角色交集判定,见 spec §4)
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

  defp audit_logs do
    Repo.all(
      from a in "audit_logs",
        order_by: [asc: a.inserted_at],
        select: %{
          id: type(a.id, :string),
          action: a.action,
          resource: a.resource,
          workspace_id: type(a.workspace_id, :string),
          actor_id: type(a.actor_id, :string),
          client: a.client,
          result: a.result,
          inserted_at: a.inserted_at
        }
    )
  end

  # ---------- 验收点 1: 权限矩阵逐操作 ----------

  describe "验收点1: 权限矩阵逐操作判定" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    test "Workflow: Owner 创建 → 201;Learner 创建(越权)→ 403", %{owner: owner, ws: ws} do
      learner = member(ws, "Learner")

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", %{"name" => "wf-1", "description" => "d"})

      assert json_response(conn, 201)["workflow"]["name"] == "wf-1"

      conn =
        auth_conn(learner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", %{"name" => "wf-2"})

      assert response(conn, 403)
    end

    test "Step 执行: 成员角色∩Step允许角色交集非空 → 200;交集空 → 403", %{owner: owner, ws: ws} do
      tutor = member(ws, "Tutor")
      learner = member(ws, "Learner")

      # seed workflow + step + step_role(Tutor 允许)
      {:ok, wf} =
        Ash.create(Cgc2046.Workspaces.Workflow, %{name: "wf"},
          tenant: ws.id,
          authorize?: false
        )

      {:ok, step} =
        Ash.create(Cgc2046.Workspaces.Step, %{title: "s1", position: 1, workflow_id: wf.id},
          tenant: ws.id,
          authorize?: false
        )

      tutor_role = role(ws, "Tutor")

      Ash.create!(Cgc2046.Workspaces.StepRole, %{step_id: step.id, role_id: tutor_role.id},
        tenant: ws.id,
        authorize?: false
      )

      # Tutor(角色交集非空)→ 200
      conn = auth_conn(tutor) |> post("/api/v1/workspaces/#{ws.id}/steps/#{step.id}/execute", %{})
      assert json_response(conn, 200)["executed"] == true

      # Learner(角色交集空)→ 403
      conn = auth_conn(learner) |> post("/api/v1/workspaces/#{ws.id}/steps/#{step.id}/execute", %{})
      assert response(conn, 403)
    end

    test "邀请: Owner/Volunteer 生成 → 201;Learner → 403;Volunteer 预授权 Admin → 403;Owner 预授权 Admin → 201",
         %{owner: owner, ws: ws} do
      volunteer = member(ws, "Volunteer")
      learner = member(ws, "Learner")
      admin_role = role(ws, "Admin")
      expires = "2026-12-31T00:00:00Z"

      # Owner 生成 → 201,返回明文 token,status active
      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/invitations", %{"expires_at" => expires})

      inv = json_response(conn, 201)["invitation"]
      assert inv["token"]
      assert inv["status"] == "active"

      # Volunteer 生成(无预授权)→ 201
      conn =
        auth_conn(volunteer)
        |> post("/api/v1/workspaces/#{ws.id}/invitations", %{"expires_at" => expires})

      assert response(conn, 201)

      # Learner 生成 → 403
      conn =
        auth_conn(learner)
        |> post("/api/v1/workspaces/#{ws.id}/invitations", %{"expires_at" => expires})

      assert response(conn, 403)

      # Volunteer 预授权 Admin 级角色 → 403
      conn =
        auth_conn(volunteer)
        |> post("/api/v1/workspaces/#{ws.id}/invitations", %{
          "expires_at" => expires,
          "preauthorized_role_ids" => [admin_role.id]
        })

      assert response(conn, 403)

      # Owner 预授权 Admin 级角色 → 201
      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/invitations", %{
          "expires_at" => expires,
          "preauthorized_role_ids" => [admin_role.id]
        })

      assert response(conn, 201)
    end
  end

  # ---------- 验收点 2: 每次 API 请求落审计 ----------

  describe "验收点2: 每次 API 请求(成功或失败)落审计" do
    test "成功/越权/未认证请求各落一条,字段齐全" do
      user = TestFixtures.seed_user()
      token = TestFixtures.seed_token(user)

      # 成功请求 → 200
      conn = build_conn() |> with_bearer_token(token) |> get("/api/v1/me")
      assert response(conn, 200)

      # 越权请求(普通用户创建 workspace)→ 403
      conn =
        build_conn()
        |> with_bearer_token(token)
        |> post("/api/v1/workspaces", %{"slug" => "audit-ws", "name" => "x", "owner_id" => user.id})

      assert response(conn, 403)

      # 未认证请求 → 401
      conn = build_conn() |> get("/api/v1/me")
      assert response(conn, 401)

      logs = audit_logs()

      # 成功请求落表(actor/action/resource/result)
      assert Enum.any?(logs, fn l ->
               l.action == "GET /api/v1/me" and l.result == "200" and l.actor_id == user.id and
                 l.resource == "me"
             end)

      # 越权请求落表(result=403)
      assert Enum.any?(logs, fn l ->
               l.action == "POST /api/v1/workspaces" and l.result == "403" and
                 l.actor_id == user.id
             end)

      # 未认证请求落表(actor_id 为空,result=401)
      assert Enum.any?(logs, fn l ->
               l.action == "GET /api/v1/me" and l.result == "401" and is_nil(l.actor_id)
             end)

      # 时间戳存在
      assert Enum.all?(logs, & &1.inserted_at)
    end

    test "X-CGC-Client 与 workspace_id 落表" do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      token = TestFixtures.seed_token(owner)

      conn =
        build_conn()
        |> put_req_header("x-cgc-client", "web")
        |> with_bearer_token(token)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", %{"name" => "wf-audit"})

      assert response(conn, 201)

      log =
        Enum.find(audit_logs(), fn l -> l.action == "POST /api/v1/workspaces/#{ws.id}/workflows" end)

      assert log
      assert log.workspace_id == ws.id
      assert log.client == "web"
      assert log.resource == "workspaces"
      assert log.result == "201"
    end
  end

  # ---------- 验收点 3: 审计查询隔离 ----------

  describe "验收点3: 审计查询隔离" do
    test "用户查自己的;Owner 查 workspace 的;非 Owner 查 workspace → 403" do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      learner = member(ws, "Learner")
      owner_token = TestFixtures.seed_token(owner)
      learner_token = TestFixtures.seed_token(learner)

      # 产生一条 ws 审计记录(owner 创建 workflow)
      conn =
        build_conn()
        |> with_bearer_token(owner_token)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", %{"name" => "wf-iso"})

      assert response(conn, 201)

      # 用户查自己的 → 200,只含自己的记录(不含 owner 的 ws 记录)
      conn = build_conn() |> with_bearer_token(learner_token) |> get("/api/v1/audit_logs")
      body = json_response(conn, 200)
      assert Enum.all?(body["audit_logs"], fn l -> l["actor_id"] == learner.id end)

      # Owner 查 workspace 的 → 200,含 ws 记录
      conn =
        build_conn()
        |> with_bearer_token(owner_token)
        |> get("/api/v1/workspaces/#{ws.id}/audit_logs")

      body = json_response(conn, 200)
      assert Enum.any?(body["audit_logs"], fn l -> l["workspace_id"] == ws.id end)

      # 非 Owner 成员查 workspace 的 → 403
      conn =
        build_conn()
        |> with_bearer_token(learner_token)
        |> get("/api/v1/workspaces/#{ws.id}/audit_logs")

      assert response(conn, 403)
    end
  end
end
