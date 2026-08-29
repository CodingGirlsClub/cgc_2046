defmodule Cgc2046.Mcp.CourseToolsTest do
  @moduledoc """
  课程学习四工具测试(切片 H U3, #180;直接调 tool execute/2,不走 HTTP)。

  七场景(按 plan U3):
  1. 学员(confirmed enrollment、非成员)四工具中的三学员侧全通(名单生效)
  2. 未报名非成员:读拒、写拒;曾学过(有记忆)读放行
  3. tutor 保存内容成功并镜像 facts;owner/admin 放行;learner 拒(R6)
  4. 课程 close 后 save_learning_records 业务错误、两读工具正常(AE2)
  5. run succeeded 后 save_learning_records 成功(AE3 缝级前置)
  6. get_learning_records 缺省 course_id 多课程;带 course_id 过滤
  7. server 注册工具数 = 20 契约断言
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.Tools.GetCourseContent
  alias Cgc2046.Mcp.Tools.GetLearningRecords
  alias Cgc2046.Mcp.Tools.SaveCourseContent
  alias Cgc2046.Mcp.Tools.SaveLearningRecords

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp content_fixture do
    %{
      "goals" => ["能写简单程序"],
      "issues" => [
        %{
          "id" => "py-first-program",
          "kind" => "handwork",
          "title" => "写你的第一个程序",
          "story" => %{
            "as_a" => "学员",
            "given" => [],
            "goal" => "独立写问候程序",
            "materials" => [],
            "checklist" => [
              %{"id" => "c1", "text" => "程序能运行并正确输出"},
              %{"id" => "c2", "text" => "能讲懂代码"}
            ]
          }
        }
      ]
    }
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  defp save_content(user, workspace, course, content \\ nil, base_version \\ 0) do
    SaveCourseContent.execute(
      %{
        "workspace_id" => workspace.id,
        "course_id" => course.id,
        "content" => content || content_fixture(),
        "base_version" => base_version
      },
      frame_for(user)
    )
  end

  defp save_records(user, workspace, course, issue_id \\ "py-first-program") do
    SaveLearningRecords.execute(
      %{
        "workspace_id" => workspace.id,
        "course_id" => course.id,
        "issue_id" => issue_id,
        "records" => [%{"item_id" => "c1", "done" => true, "evidence" => "跑通了"}]
      },
      frame_for(user)
    )
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(Cgc2046.Workflows.WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  describe "场景 1:学员(confirmed enrollment、非成员)三学员侧工具全通" do
    test "名单生效:读内容、读写记录均放行" do
      admin = Fixtures.platform_admin("ct-learner")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("ct-learner-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})
      learner = Fixtures.register_user("ct-learner-student")

      enrollment = enroll(course, learner)
      assert enrollment.status == :confirmed
      assert {:reply, _, _} = save_content(tutor, workspace, course)

      assert {:reply, _, _} =
               content_reply =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(learner)
               )

      # H2/H3:响应带课程名 + 逐 issue 展示层 key(slug 短码-序号)
      content_payload = decode(content_reply)
      assert content_payload["course_title"] == "课程"

      assert [first_issue] = content_payload["issues"]
      assert %{"key" => key} = first_issue
      # fixtures slug 为随机码("c-xxxx");断言形状:非空短码 + "-01" 序号
      assert key =~ ~r/\A[A-Z0-9]{1,4}-01\z/

      assert {:reply, _, _} = save_records(learner, workspace, course)

      assert {:reply, _, _} =
               GetLearningRecords.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(learner)
               )
    end
  end

  describe "场景 2:未报名非成员拒;有记忆读放行" do
    test "读拒、写拒" do
      admin = Fixtures.platform_admin("ct-outsider")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      outsider = Fixtures.register_user("ct-outsider-user")

      assert {:error, %Anubis.MCP.Error{message: msg1}, _} =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(outsider)
               )

      assert msg1 =~ "forbidden"

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               save_records(outsider, workspace, course)

      assert msg2 =~ "forbidden"
    end

    test "曾学过(有记忆)读放行" do
      admin = Fixtures.platform_admin("ct-memory")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      tutor = Fixtures.register_user("ct-memory-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      past = Fixtures.register_user("ct-memory-user")
      enroll(course, past)

      # 教研产出已存(读内容才有的读)
      assert {:reply, _, _} = save_content(tutor, workspace, course)

      assert {:reply, _, _} = save_records(past, workspace, course)

      # 报名被取消(cancel 后 enrollment 非 confirmed),记忆持有者读仍放行
      [enrollment] =
        Enrollment
        |> Ash.Query.filter(course_id == ^course.id and user_id == ^past.id)
        |> Ash.read!(authorize?: false)

      enrollment
      |> Ash.Changeset.for_update(:cancel, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert {:reply, _, _} =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(past)
               )
    end
  end

  describe "场景 3:save_course_content 授权与 facts 镜像" do
    test "tutor 保存成功;非终态 run facts 镜像 issues;owner/admin 放行;learner 拒" do
      admin = Fixtures.platform_admin("ct-tutor")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("ct-tutor-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      learner_member = Fixtures.register_user("ct-tutor-learner")
      Fixtures.add_member(workspace, learner_member, [:learner])
      course = EventFixtures.create_course(workspace, admin, %{})

      # 造一个非终态教研 run 并挂到 course(镜像目标)
      # 造一个非终态教研 run 并挂到 course(镜像目标):走 Curriculum.Instantiator
      # 正道(manual step → waiting 非终态)
      {:ok, published} =
        Cgc2046.Workflows.WorkflowDefinition
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "教研",
            type: :curriculum,
            input_schema: %{},
            node_def: %{"steps" => [%{"id" => "draft_issues", "type" => "manual"}]}
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)
        |> then(fn {:ok, defn} ->
          defn
          |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
          |> Ash.update(tenant: workspace.id, actor: admin)
        end)

      {:ok, run} =
        Cgc2046.Curriculum.Instantiator.launch(
          workspace.id,
          published.id,
          %{"course_id" => course.id, "title" => course.title, "research_requirements" => %{}},
          :course
        )

      assert run.status in [:waiting, :running]

      course
      |> Ash.Changeset.for_update(:link_curriculum_run, %{workflow_run_id: run.id},
        tenant: workspace.id,
        authorize?: false
      )
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      # tutor 保存成功(首存 base_version=0 → version 1)
      assert {:reply, _, _} = reply = save_content(tutor, workspace, course)
      payload = decode(reply)
      assert payload["status"] == "saved"
      assert payload["key"] == "course_#{course.id}"
      assert payload["version"] == 1

      # facts 镜像:非终态 run 的 facts["issues"] 浅合并
      mirrored = fetch_run(run.id, workspace.id)
      assert mirrored.facts["issues"]["goals"] == ["能写简单程序"]

      # owner/admin 放行(第二次写入,base_version=1)
      assert {:reply, _, _} = save_content(admin, workspace, course, nil, 1)

      # learner 成员拒(R6)
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save_content(learner_member, workspace, course)

      assert msg =~ "forbidden"
    end
  end

  describe "场景 4:课程终态拒写保读(AE2)" do
    test "close 后 save_learning_records 业务错误;两读工具正常" do
      admin = Fixtures.platform_admin("ct-close")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("ct-close-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{})
      learner = Fixtures.register_user("ct-close-student")
      enroll(course, learner)
      {:reply, _, _} = save_content(tutor, workspace, course)

      # 先写一条记忆(成为记忆持有者,close 后读的授权锚)
      assert {:reply, _, _} = save_records(learner, workspace, course)

      course
      |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id, actor: admin)
      |> Ash.update!(tenant: workspace.id, actor: admin)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               save_records(learner, workspace, course)

      assert msg =~ "read-only" or msg =~ "closed"

      assert {:reply, _, _} =
               GetCourseContent.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(learner)
               )

      assert {:reply, _, _} =
               GetLearningRecords.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(learner)
               )
    end
  end

  describe "场景 5:run 终态后记录仍可写(AE3 缝级前置)" do
    test "succeeded 后 save_learning_records 成功" do
      admin = Fixtures.platform_admin("ct-succ")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      learner = Fixtures.register_user("ct-succ-student")
      enrollment = enroll(course, learner)

      # 造 succeeded 学习 run 挂到 enrollment
      # 造 succeeded 学习 run 挂到 enrollment(create → start → complete 正道)
      {:ok, published} =
        Cgc2046.Workflows.WorkflowDefinition
        |> Ash.Changeset.for_create(
          :create,
          %{name: "学习", type: :learning, input_schema: %{}, node_def: %{"steps" => []}},
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)
        |> then(fn {:ok, defn} ->
          defn
          |> Ash.Changeset.for_update(:publish, %{}, actor: admin)
          |> Ash.update(tenant: workspace.id, actor: admin)
        end)

      {:ok, run} =
        Cgc2046.Workflows.WorkflowRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            definition_id: published.id,
            definition_version: published.version,
            input_snapshot: %{
              "key" => "enrollment_#{enrollment.id}",
              "enrollment_id" => enrollment.id,
              "user_id" => learner.id,
              "course_id" => course.id
            }
          },
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      run =
        run
        |> Ash.Changeset.for_update(:start, %{}, tenant: workspace.id, authorize?: false)
        |> Ash.update!(tenant: workspace.id, authorize?: false)
        |> then(fn running ->
          running
          |> Ash.Changeset.for_update(:complete, %{}, tenant: workspace.id, authorize?: false)
          |> Ash.update!(tenant: workspace.id, authorize?: false)
        end)

      assert {:reply, _, _} = reply = save_records(learner, workspace, course)
      payload = decode(reply)
      assert payload["saved"] == 1

      # 记录行落库,run 状态不变
      assert fetch_run(run.id, workspace.id).status == :succeeded
    end
  end

  describe "跨租户越权(F1 回归:A 成员 + B course_id 两写工具均拒)" do
    test "save_course_content / save_learning_records 均报 course not found" do
      admin_b = Fixtures.platform_admin("ct-xtenant-b")
      workspace_b = Fixtures.create_workspace(admin_b)
      course_b = EventFixtures.create_course(workspace_b, admin_b, %{title: "B 租户课程"})

      # A 租户:tutor 成员(对 A 有完整写权限)
      admin_a = Fixtures.platform_admin("ct-xtenant-a")
      workspace_a = Fixtures.create_workspace(admin_a)
      tutor_a = Fixtures.register_user("ct-xtenant-a-tutor")
      Fixtures.add_member(workspace_a, tutor_a, [:tutor])

      # A tutor 用 workspace_id=A + B 课程 id:fetch_course 按 tenant 过滤读不到
      # → course not found(不泄露跨租户存在性)
      assert {:error, %Anubis.MCP.Error{message: msg1}, _} =
               SaveCourseContent.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "course_id" => course_b.id,
                   "content" => content_fixture(),
                   "base_version" => 0
                 },
                 frame_for(tutor_a)
               )

      assert msg1 =~ "course not found"

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               SaveLearningRecords.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "course_id" => course_b.id,
                   "issue_id" => "py-first-program",
                   "records" => [%{"item_id" => "c1", "done" => true, "evidence" => "越权"}]
                 },
                 frame_for(tutor_a)
               )

      assert msg2 =~ "course not found"

      # B 租户内容与记录面未被 A 触碰(零行落地)
      assert Cgc2046.Learning.LearningRecord
             |> Ash.Query.filter(course_id == ^course_b.id)
             |> Ash.read!(authorize?: false) == []

      assert Cgc2046.Curriculum.Output
             |> Ash.Query.filter(key == ^"course_#{course_b.id}")
             |> Ash.read!(authorize?: false) == []
    end
  end

  describe "done 标志(F2 回归:false 不被吞)" do
    test "done: false 直接写入成功" do
      admin = Fixtures.platform_admin("ct-f2-false")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      learner = Fixtures.register_user("ct-f2-false-learner")
      enroll(course, learner)

      assert {:reply, _, _} =
               SaveLearningRecords.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "issue_id" => "py-first-program",
                   "records" => [%{"item_id" => "c1", "done" => false, "evidence" => "复盘中"}]
                 },
                 frame_for(learner)
               )

      assert [row] =
               Cgc2046.Learning.LearningRecord
               |> Ash.Query.filter(course_id == ^course.id and user_id == ^learner.id)
               |> Ash.read!(authorize?: false)

      assert row.done == false
    end

    test "upsert 翻转:true → false(最新为准,不吞 false)" do
      admin = Fixtures.platform_admin("ct-f2-flip")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      learner = Fixtures.register_user("ct-f2-flip-learner")
      enroll(course, learner)

      # 先写 true
      assert {:reply, _, _} = save_records(learner, workspace, course)

      # 同键翻回 false(撤销/显式未完成)
      assert {:reply, _, _} =
               SaveLearningRecords.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "issue_id" => "py-first-program",
                   "records" => [%{"item_id" => "c1", "done" => false, "evidence" => "撤销"}]
                 },
                 frame_for(learner)
               )

      assert [row] =
               Cgc2046.Learning.LearningRecord
               |> Ash.Query.filter(course_id == ^course.id and user_id == ^learner.id)
               |> Ash.read!(authorize?: false)

      assert row.done == false
      assert row.evidence == "撤销"
    end
  end

  describe "场景 6:get_learning_records 视角" do
    test "缺省 course_id 返回本人多课程;带 course_id 过滤" do
      admin = Fixtures.platform_admin("ct-multi")
      workspace = Fixtures.create_workspace(admin)
      course_a = EventFixtures.create_course(workspace, admin, %{title: "A"})
      course_b = EventFixtures.create_course(workspace, admin, %{title: "B"})
      learner = Fixtures.register_user("ct-multi-student")
      enroll(course_a, learner)
      enroll(course_b, learner)

      assert {:reply, _, _} = save_records(learner, workspace, course_a)

      assert {:reply, _, _} =
               SaveLearningRecords.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course_b.id,
                   "issue_id" => "another-issue",
                   "records" => [%{"item_id" => "c9", "done" => true, "evidence" => "b 课"}]
                 },
                 frame_for(learner)
               )

      assert {:reply, _, _} =
               all_reply =
               GetLearningRecords.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(learner)
               )

      all = decode(all_reply)
      assert all["count"] == 2
      assert length(Enum.uniq(Enum.map(all["records"], & &1["course_id"]))) == 2

      assert {:reply, _, _} =
               one_reply =
               GetLearningRecords.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course_a.id},
                 frame_for(learner)
               )

      one = decode(one_reply)
      assert one["count"] == 1
      assert hd(one["records"])["course_id"] == course_a.id
    end
  end

  describe "场景 7:server 工具契约" do
    test "注册工具数 = 43(平台工具面契约,S3 工作台管理面十三工具后)" do
      tools = Server.__components__(:tool)
      names = Enum.map(tools, & &1.name)

      assert length(names) == 43

      for name <- [
            "get_workspace_context",
            "list_members",
            "list_join_requests",
            "get_workflow",
            "get_step_output",
            "save_step_output",
            "create_invitation",
            "approve_join_request",
            "assign_roles",
            "confirm_operation",
            "cancel_operation",
            "get_course_content",
            "get_learning_records",
            "save_learning_records",
            "save_course_content",
            "list_public_offerings",
            "get_public_offering",
            "list_my_workspaces",
            "get_role_playbook",
            "list_my_tasks",
            "admin_list_users",
            "admin_list_workspaces",
            "admin_list_workspace_applications",
            "admin_list_audit_logs",
            "admin_approve_workspace_application",
            "admin_reject_workspace_application",
            "admin_create_workspace",
            "admin_reassign_workspace_owner",
            "admin_promote_user",
            "admin_demote_user",
            "create_course",
            "update_course",
            "launch_course",
            "close_course",
            "cancel_course",
            "list_course_enrollments",
            "confirm_enrollment",
            "reject_enrollment",
            "waive_payment",
            "list_workspace_orders",
            "refund_order",
            "retry_refund",
            "update_join_policy"
          ] do
        assert name in names, "expected tool #{name} registered"
      end
    end
  end
end
