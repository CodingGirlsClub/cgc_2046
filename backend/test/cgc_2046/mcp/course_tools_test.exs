defmodule Cgc2046.Mcp.CourseToolsTest do
  @moduledoc """
  课程学习四工具测试(切片 H U3, #180;直接调 tool execute/2,不走 HTTP)。

  场景(按 plan U3;S8 学习记录面已删,场景 1/2/4/5/6 的记录部分随
  LearningRecord 退役——等价覆盖在 learning_loop_tools_test):
  1. 学员(confirmed enrollment、非成员)四工具中的三学员侧全通(名单生效)
  2. 未报名非成员:读拒、写拒;曾学过(有记忆)读放行
  3. tutor 保存内容成功并镜像 facts;owner/admin 放行;learner 拒(R6)
  4. 课程 close 后 save_learning_records 业务错误、两读工具正常(AE2)
  5. run succeeded 后 save_learning_records 成功(AE3 缝级前置)
  6. get_learning_records 缺省 course_id 多课程;带 course_id 过滤
  7. server 注册工具数 = 60 契约断言(S10 学习分析工具后)
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.Tools.GetCourseContent
  alias Cgc2046.Mcp.Tools.ListWorkspaceCourses
  alias Cgc2046.Mcp.Tools.SaveCourseContent

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
          },
          "objectives" => [
            %{
              "id" => "obj-1",
              "title" => "掌握本单元核心目标",
              "rubric" => [%{"id" => "r1", "text" => "能独立完成"}]
            }
          ]
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

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(Cgc2046.Workflows.WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
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

      # S6 起 Instantiator event-only——course 型教研 run 布景改经
      # WorkflowRun 统一入口直造（instance key 约定 "course_<id>"，镜像语义不变）
      {:ok, run, _} =
        Cgc2046.Workflows.WorkflowRun.find_or_create_and_start(
          workspace.id,
          published,
          %{"course_id" => course.id, "title" => course.title, "research_requirements" => %{}},
          key: "course_#{course.id}"
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

  describe "跨租户越权(F1 回归:A 成员 + B course_id 写工具均拒)" do
    test "save_course_content / submit_learning_attempt 均报 course not found(或前置拒)" do
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

      # submit_learning_attempt:非 confirmed enrollment 的 tutor 提交 →
      # forbidden(授权账本前置,不触碰 B 租户)
      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               Cgc2046.Mcp.Tools.SubmitLearningAttempt.execute(
                 %{
                   "workspace_id" => workspace_a.id,
                   "course_id" => course_b.id,
                   "objective_id" => "obj-1",
                   "evidence" => "越权",
                   "rubric_results" => [%{"criterion_id" => "r1", "met" => true}],
                   "passed" => true,
                   "rationale" => "越权",
                   "confidence" => 0.9
                 },
                 frame_for(tutor_a)
               )

      assert msg2 =~ "forbidden"

      # B 租户内容面未被 A 触碰(零行落地)
      assert Cgc2046.Curriculum.Output
             |> Ash.Query.filter(key == ^"course_#{course_b.id}")
             |> Ash.read!(authorize?: false) == []

      assert Cgc2046.Learning.Attempt
             |> Ash.Query.filter(course_revision_id == ^course_b.current_revision_id)
             |> Ash.read!(authorize?: false) == []
    end
  end

  describe "list_workspace_courses（#366 member-only 课程发现面）" do
    test "member（tutor）见本台全部状态课程含 draft；status 过滤；非 member forbidden" do
      admin = Fixtures.platform_admin("cwlc-admin")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("cwlc-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      outsider = Fixtures.register_user("cwlc-outsider")

      # draft（fixture 会 force_open，draft 态绕过直建）+ open 各一门
      assert {:ok, draft} =
               Cgc2046.Courses.Course
               |> Ash.Changeset.for_create(:create, %{title: "CWLC Draft"},
                 tenant: workspace.id,
                 actor: admin
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

      open = EventFixtures.create_course(workspace, admin, %{title: "CWLC Open"})

      # tutor（member，非管理角色）→ 全部状态含 draft
      {:reply, _, _} =
        reply = ListWorkspaceCourses.execute(%{"workspace_id" => workspace.id}, frame_for(tutor))

      decoded = decode(reply)
      assert decoded["count"] == 2

      titles = Enum.map(decoded["courses"], & &1["title"])
      assert Enum.sort(titles) == ["CWLC Draft", "CWLC Open"]

      for row <- decoded["courses"] do
        assert Map.has_key?(row, "course_id")
        assert Map.has_key?(row, "status")
        assert Map.has_key?(row, "visibility")
        assert Map.has_key?(row, "current_revision_id")
        assert Map.has_key?(row, "prep_state")
      end

      draft_row = Enum.find(decoded["courses"], &(&1["course_id"] == draft.id))
      assert draft_row["status"] == "draft"

      # status 过滤：只剩 draft
      {:reply, _, _} =
        filtered =
        ListWorkspaceCourses.execute(
          %{"workspace_id" => workspace.id, "status" => "draft"},
          frame_for(tutor)
        )

      filtered_rows = decode(filtered)["courses"]
      assert [%{"status" => "draft"}] = filtered_rows

      # 非 member → Wrapper member-only 门 forbidden
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListWorkspaceCourses.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(outsider)
               )

      assert msg =~ "not a member"

      # 非法 status → 明确清单报错
      assert {:error, %Anubis.MCP.Error{message: status_msg}, _} =
               ListWorkspaceCourses.execute(
                 %{"workspace_id" => workspace.id, "status" => "bogus"},
                 frame_for(tutor)
               )

      assert status_msg =~ "invalid status"
    end
  end

  describe "场景 7:server 工具契约" do
    test "注册工具数 = 62(平台工具面契约,list_workspace_courses 后)" do
      tools = Server.__components__(:tool)
      names = Enum.map(tools, & &1.name)

      assert length(names) == 62

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
            "save_course_content",
            "start_learning_run",
            "submit_learning_attempt",
            "get_learning_state",
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
            "update_join_policy",
            "get_prep_status",
            "assign_prep_tutor",
            "claim_prep_authoring",
            "update_prep_policy",
            "submit_prep_for_check",
            "submit_prep_quality_report",
            "override_prep_gate",
            "approve_prep",
            "request_changes_prep"
          ] do
        assert name in names, "expected tool #{name} registered"
      end
    end
  end
end
