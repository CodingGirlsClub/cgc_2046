defmodule Cgc2046Web.T08WorkflowDeployTest do
  @moduledoc """
  T08 验收(HTTP 集成):Workflow DSL 构建与部署(spec §6/§7,issue #9)。

  验收点:
  1. 合法 DSL 部署 → Workflow+Step 落库(含 dsl_version)
  2. 同 name+workspace 重复部署 → 幂等更新(不重复建 Workflow)
  3. 非法 DSL(position 乱序 / allowed_roles 引用不存在角色 / type 非法)→ 422
  4. 无部署权限角色(Learner/Volunteer)→ 403
  5. Step N+1 在 Step N 完成前不可执行(Step 顺序解锁)
  6. 归档的 Workflow 不可执行

  授权语义:部署 = `workflow:deploy`(Owner/Admin/Tutor);Step 执行 = 角色交集
  非空 + Workflow 未归档 + 前序 Steps 全部 completed。
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

  defp auth_conn(user) do
    build_conn() |> with_bearer_token(TestFixtures.seed_token(user))
  end

  defp deploy_payload(name, steps) do
    base = %{
      "name" => name,
      "description" => "T08 测试 Workflow",
      "dsl_version" => 1
    }

    if steps do
      Map.put(base, "steps", steps)
    else
      base
    end
  end

  defp default_steps do
    [
      %{"position" => 1, "title" => "大纲设计", "type" => "content", "allowed_roles" => ["Tutor"], "agent_hint" => "设计大纲"},
      %{"position" => 2, "title" => "答疑", "type" => "discussion", "allowed_roles" => ["Tutor", "Learner"], "agent_hint" => "答疑讨论"}
    ]
  end

  defp db_workflow(id) do
    Repo.get_by!(Cgc2046.Workspaces.Workflow, id: id)
  end

  defp db_steps(workflow_id) do
    Repo.all(
      from s in "steps",
        where: s.workflow_id == ^Ecto.UUID.dump!(workflow_id),
        order_by: [asc: s.position],
        select: %{
          id: type(s.id, :string),
          title: s.title,
          position: s.position,
          type: s.type,
          status: s.status
        }
    )
  end

  defp db_step_role_count(step_id) do
    Repo.one(
      from sr in "step_roles",
        where: sr.step_id == ^Ecto.UUID.dump!(step_id),
        select: count(sr.id)
    ) || 0
  end

  # ---------- 验收点 1: 合法 DSL 部署 ----------

  describe "验收点1: 合法 DSL 部署 → Workflow+Step 落库(含 dsl_version)" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    test "Tutor 部署合法 DSL → 201,Workflow+2 Step+StepRole 落库,dsl_version=1", %{owner: _owner, ws: ws} do
      tutor = member(ws, "Tutor")
      name = "html-101-#{System.unique_integer([:positive])}"

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload(name, default_steps()))

      wf = json_response(conn, 201)["workflow"]
      assert wf["name"] == name
      assert wf["dsl_version"] == 1
      assert wf["status"] == "published"

      db_wf = db_workflow(wf["id"])
      assert db_wf.name == name
      assert db_wf.dsl_version == 1
      assert db_wf.status == "published"

      steps = db_steps(wf["id"])
      assert length(steps) == 2
      assert Enum.map(steps, & &1.position) == [1, 2]
      assert Enum.map(steps, & &1.status) == ["pending", "pending"]

      # StepRole 落库(Tutor 允许 step1;Tutor+Learner 允许 step2)
      assert Enum.all?(steps, &(db_step_role_count(&1.id) >= 1))
    end
  end

  # ---------- 验收点 2: 幂等部署 ----------

  describe "验收点2: 同 name+workspace 重复部署 → 幂等更新" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    test "重复部署同名 Workflow → 更新而非新建(id 不变,steps 重建)", %{owner: _owner, ws: ws} do
      tutor = member(ws, "Tutor")
      name = "idem-#{System.unique_integer([:positive])}"

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload(name, default_steps()))

      first = json_response(conn, 201)["workflow"]
      assert first["status"] == "published"

      # 第二次部署:steps 变化(position 顺序/数量不同)
      changed_steps = [
        %{"position" => 1, "title" => "新标题", "type" => "content", "allowed_roles" => ["Tutor"]},
        %{"position" => 2, "title" => "答疑", "type" => "discussion", "allowed_roles" => ["Tutor", "Learner"]},
        %{"position" => 3, "title" => "问卷", "type" => "survey", "allowed_roles" => ["Learner"]}
      ]

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload(name, changed_steps))

      second = json_response(conn, 200)["workflow"]
      assert second["id"] == first["id"]
      assert second["status"] == "published"

      # Workflow 表只有 1 条
      count =
        Repo.one(
          from(w in "workflows", where: w.name == ^name, select: count(w.id))
        )

      assert count == 1

      steps = db_steps(first["id"])
      assert length(steps) == 3
      assert Enum.map(steps, & &1.title) == ["新标题", "答疑", "问卷"]
    end
  end

  # ---------- 验收点 3: 非法 DSL → 422 ----------

  describe "验收点3: 非法 DSL(position 乱序 / 角色不存在 / type 非法)→ 422" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    test "position 乱序(不连续)→ 422", %{owner: owner, ws: ws} do
      bad_steps = [
        %{"position" => 1, "title" => "s1", "type" => "content", "allowed_roles" => ["Tutor"]},
        %{"position" => 3, "title" => "s3", "type" => "content", "allowed_roles" => ["Tutor"]}
      ]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("bad-pos", bad_steps))

      assert response(conn, 422)
    end

    test "allowed_roles 引用不存在的角色 → 422", %{owner: owner, ws: ws} do
      bad_steps = [
        %{"position" => 1, "title" => "s1", "type" => "content", "allowed_roles" => ["Ghost"]}
      ]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("bad-role", bad_steps))

      assert response(conn, 422)
    end

    test "type 非法 → 422", %{owner: owner, ws: ws} do
      bad_steps = [
        %{"position" => 1, "title" => "s1", "type" => "hack", "allowed_roles" => ["Tutor"]}
      ]

      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("bad-type", bad_steps))

      assert response(conn, 422)
    end
  end

  # ---------- 验收点 4: 无部署权限 → 403 ----------

  describe "验收点4: 无部署权限角色(Learner/Volunteer)→ 403" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)
      %{owner: owner, ws: ws}
    end

    test "Learner 部署 → 403", %{owner: _owner, ws: ws} do
      learner = member(ws, "Learner")

      conn =
        auth_conn(learner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("learner-wf", default_steps()))

      assert response(conn, 403)
    end

    test "Volunteer 部署 → 403", %{owner: _owner, ws: ws} do
      volunteer = member(ws, "Volunteer")

      conn =
        auth_conn(volunteer)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("vol-wf", default_steps()))

      assert response(conn, 403)
    end

    test "Owner 部署 → 201(对照)", %{owner: owner, ws: ws} do
      conn =
        auth_conn(owner)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("owner-wf", default_steps()))

      assert response(conn, 201)
    end
  end

  # ---------- 验收点 5: Step 顺序解锁 ----------

  describe "验收点5: Step N+1 在 Step N 完成前不可执行(顺序解锁)" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)

      tutor = member(ws, "Tutor")

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("seq-#{System.unique_integer([:positive])}", default_steps()))

      wf = json_response(conn, 201)["workflow"]
      steps = db_steps(wf["id"])
      %{owner: owner, ws: ws, tutor: tutor, wf: wf, steps: steps}
    end

    test "step2 在 step1 完成前不可执行 → 403;step1 完成后 → step2 可执行", %{ws: ws, tutor: tutor, steps: steps} do
      [step1, step2] = steps

      # step1 未完成时执行 step2 → 403
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step2.id}/execute", %{})

      assert response(conn, 403)

      # 执行 step1 → 200
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step1.id}/execute", %{})

      assert json_response(conn, 200)["executed"] == true

      # step1 未完成(仅 in_progress)时 step2 仍不可执行 → 403
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step2.id}/execute", %{})

      assert response(conn, 403)

      # 完成 step1 → 200,status completed
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step1.id}/complete", %{})

      assert json_response(conn, 200)["step"]["status"] == "completed"

      # step1 完成后执行 step2 → 200
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step2.id}/execute", %{})

      assert json_response(conn, 200)["executed"] == true
    end
  end

  # ---------- 验收点 6: 归档的 Workflow 不可执行 ----------

  describe "验收点6: 归档的 Workflow 不可执行" do
    setup do
      owner = TestFixtures.seed_user()
      ws = TestFixtures.seed_workspace(owner: owner)

      tutor = member(ws, "Tutor")

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows", deploy_payload("arc-#{System.unique_integer([:positive])}", default_steps()))

      wf = json_response(conn, 201)["workflow"]
      steps = db_steps(wf["id"])
      %{owner: owner, ws: ws, tutor: tutor, wf: wf, steps: steps}
    end

    test "归档后 Step 执行 → 403;/me 可执行列表不再包含该 Workflow 的 Step", %{ws: ws, tutor: tutor, wf: wf, steps: steps} do
      # 归档
      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/workflows/#{wf["id"]}/archive", %{})

      assert json_response(conn, 200)["workflow"]["status"] == "archived"

      # 归档后执行任一 step → 403
      step = hd(steps)

      conn =
        auth_conn(tutor)
        |> post("/api/v1/workspaces/#{ws.id}/steps/#{step.id}/execute", %{})

      assert response(conn, 403)

      # /me 可执行步骤不再包含归档 workflow 的步骤
      conn = auth_conn(tutor) |> get("/api/v1/me")
      executable_ids = Enum.map(json_response(conn, 200)["executable_steps"], & &1["id"])
      refute step.id in executable_ids
    end
  end
end
