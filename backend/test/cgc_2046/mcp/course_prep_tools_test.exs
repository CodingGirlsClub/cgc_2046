defmodule Cgc2046.Mcp.CoursePrepToolsTest do
  @moduledoc """
  课程教研九工具测试（role-agent-journeys-v2 S5，R22-R28；直接调 tool
  execute/2，不走 HTTP；workspace_admin_tools_test 同款模式）。

  - 实例化：MCP/域 create 都发 course.created；投递两次恰一个 prep run
    （key/策略快照固化/course.workflow_run_id 回写）；非 draft 守卫与无定义跳过
  - 黄金链路（review ON）：指派 → 内容 → 门禁 → 报告 → 审核 → 发布全链落库；
    自审（策略指定 reviewer 为 tutor 本人）放行
  - review OFF：策略确认流改 review_required=false → 报告达标直接发布
  - 门禁失败：无内容 / 临时标题保持 authoring 且违规落 facts；launch 域 action
    与 MCP confirm 段同被教研门拦截（「课程须完成教研流程后发布」）；
    PrepGate 纯函数逐条违规
  - 低于阈值 → authoring + below_threshold_pending；带理由覆盖（确认流）→ review；
    无理由 / 无待覆盖报告 → error
  - 认领竞态（unboxed 真实事务 + Barrier）：两 tutor 并发认领恰一成一败
  - 策略冻结：进入 quality_check 后 update_prep_policy 第一段与域层双重拒绝
  - request_changes：review → authoring 且理由落 change_requests
  - list_my_tasks 三类教研行按角色分派（tutor/assignee/reviewer/owner/plain member）
  - 授权矩阵：九工具 × plain member/learner/outsider 负例 + ToolCallLog 落行
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.{Output, Prep, PrepGate, PrepInstantiator}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    ApprovePrep,
    AssignPrepTutor,
    ClaimPrepAuthoring,
    ConfirmOperation,
    CreateCourse,
    GetPrepStatus,
    LaunchCourse,
    ListMyTasks,
    OverridePrepGate,
    RequestChangesPrep,
    SaveCourseContent,
    SubmitPrepForCheck,
    SubmitPrepQualityReport,
    UpdatePrepPolicy
  }

  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.Repo

  alias Cgc2046.Workflows.{
    SignalPublishWorker,
    SignalSubscriber,
    WorkflowDefinition,
    WorkflowRun
  }

  require Ash.Query

  @tool_modules %{
    "get_prep_status" => GetPrepStatus,
    "assign_prep_tutor" => AssignPrepTutor,
    "claim_prep_authoring" => ClaimPrepAuthoring,
    "update_prep_policy" => UpdatePrepPolicy,
    "submit_prep_for_check" => SubmitPrepForCheck,
    "submit_prep_quality_report" => SubmitPrepQualityReport,
    "override_prep_gate" => OverridePrepGate,
    "approve_prep" => ApprovePrep,
    "request_changes_prep" => RequestChangesPrep
  }

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  defp pending_count do
    PendingOperation |> Ash.read!(authorize?: false) |> length()
  end

  # 草稿课程（不经 EventFixtures 的 force_open——教研链路全程需要 draft 起点；
  # workspace_admin_tools_test 同款 helper）
  defp draft_course(workspace, actor, attrs) do
    attrs =
      Map.merge(
        %{title: "S5 教研课程", registration_deadline: EventFixtures.days_from_now(7)},
        attrs
      )

    Course
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  # published course_preparation 定义（prep run 实例化前置；node_def 不经 Engine，
  # 协议而非 DAG——空 steps 合法，reconciliation_scan_worker_test 同款）
  defp create_prep_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "课程教研 #{Ecto.UUID.generate()}",
          type: :course_preparation,
          input_schema: %{},
          node_def: %{"steps" => []}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    defn
    |> Ash.Changeset.for_update(:publish, %{}, tenant: workspace.id, actor: actor)
    |> Ash.update!(tenant: workspace.id, actor: actor)
  end

  # 手动投递 course.created（测试环境 Oban manual：信号 job 只入队不执行；
  # state_based 幂等无需 idempotency_key，与生产 forwarder 同码同步投递）
  defp deliver_created(course) do
    :ok =
      SignalSubscriber.deliver(PrepInstantiator, %{
        type: "course.created",
        data: %{"course_id" => course.id, "title" => course.title}
      })
  end

  defp prep_run!(course, workspace) do
    run = Prep.fetch_run(course.id, workspace.id)
    assert run, "expected a non-terminal prep run for course #{course.id}"
    run
  end

  defp prep_runs(workspace) do
    WorkflowRun
    |> Ash.Query.filter(definition.type == :course_preparation)
    |> Ash.read!(authorize?: false, tenant: workspace.id)
  end

  defp reload_run(run, workspace),
    do: Ash.get!(WorkflowRun, run.id, tenant: workspace.id, authorize?: false)

  defp force_course_status(course, status) do
    {:ok, _} =
      Repo.query("UPDATE courses SET status = $1 WHERE id = $2", [
        status,
        Ecto.UUID.dump!(course.id)
      ])
  end

  # v1 内容形状（goals + issues[id/kind/title/story]；objectives 加严属 S6）
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

  defp save_content(user, workspace, course) do
    SaveCourseContent.execute(
      %{
        "workspace_id" => workspace.id,
        "course_id" => course.id,
        "content" => content_fixture(),
        "base_version" => 0
      },
      frame_for(user)
    )
  end

  defp confirm(actor, pending_id) do
    ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(actor))
  end

  defp confirm!(actor, pending_id) do
    {:reply, _, _} = reply = confirm(actor, pending_id)
    decode(reply)
  end

  # 布置：建课程 + 定义 + 投递信号 → prep run（返回 {course, run}）
  defp course_with_prep(workspace, owner, attrs) do
    create_prep_definition(workspace, owner)
    course = draft_course(workspace, owner, attrs)
    deliver_created(course)
    {course, prep_run!(course, workspace)}
  end

  # 布置：推进到 quality_check（指派/认领在调用方完成，此处假定 run 已 authoring
  # 且 assignee = tutor）
  defp drive_to_quality_check(workspace, course, tutor) do
    {:reply, _, _} = save_content(tutor, workspace, course)

    {:reply, _, _} =
      reply =
      SubmitPrepForCheck.execute(
        %{"workspace_id" => workspace.id, "course_id" => course.id},
        frame_for(tutor)
      )

    assert decode(reply)["passed"] == true
    :ok
  end

  defp submit_report(user, workspace, course, score) do
    SubmitPrepQualityReport.execute(
      %{
        "workspace_id" => workspace.id,
        "course_id" => course.id,
        "report" => %{"score" => score, "summary" => "评审摘要 score=#{score}"}
      },
      frame_for(user)
    )
  end

  # ── 实例化（course.created → prep run，R22） -----------------------------------

  describe "实例化（course.created → prep run）" do
    test "MCP create_course 与域 create 都发 course.created 信号（事务内 outbox 入队）" do
      owner = Fixtures.platform_admin("s5-inst-owner")
      workspace = Fixtures.create_workspace(owner)

      # MCP 入口
      assert {:reply, _, _} =
               reply =
               CreateCourse.execute(
                 %{"workspace_id" => workspace.id, "title" => "MCP 创建"},
                 frame_for(owner)
               )

      mcp_course_id = decode(reply)["course_id"]

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{"signal_type" => "course.created", "data" => %{"course_id" => mcp_course_id}}
      )

      # 域入口
      course = draft_course(workspace, owner, %{title: "域创建"})

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{"signal_type" => "course.created", "data" => %{"course_id" => course.id}}
      )
    end

    test "投递两次恰一个 prep run：key/状态/策略快照固化，课程回写 workflow_run_id" do
      owner = Fixtures.platform_admin("s5-inst-idem")
      workspace = Fixtures.create_workspace(owner)
      create_prep_definition(workspace, owner)
      course = draft_course(workspace, owner, %{title: "幂等实例化"})

      deliver_created(course)
      deliver_created(course)

      [run] = prep_runs(workspace)
      assert run.status == :running
      assert run.input_snapshot["key"] == "course_prep_#{course.id}"
      assert run.input_snapshot["course_id"] == course.id
      assert run.input_snapshot["prep_policy"] == Prep.default_policy()
      assert Prep.prep_state(run) == "draft"

      # 产物引用链回写（save_course_content facts 镜像与 workflowRun 关系的锚）
      assert Ash.get!(Course, course.id, authorize?: false).workflow_run_id == run.id
    end

    test "非 draft 课程守卫：信号重投不实例化（首投失败、课程已发布后重投的防护）" do
      owner = Fixtures.platform_admin("s5-inst-guard")
      workspace = Fixtures.create_workspace(owner)
      create_prep_definition(workspace, owner)
      course = draft_course(workspace, owner, %{title: "守卫"})

      # 布置：直接置 open（模拟「课程已发布后信号重投」；prep run 不存在时
      # launch 教研门本就放行存量课程）
      force_course_status(course, "open")

      deliver_created(course)

      assert prep_runs(workspace) == []
    end

    test "无 published course_preparation 定义 → 跳过实例化（不 raise、不建 run）" do
      owner = Fixtures.platform_admin("s5-inst-nodef")
      workspace = Fixtures.create_workspace(owner)
      course = draft_course(workspace, owner, %{title: "无定义"})

      deliver_created(course)

      assert prep_runs(workspace) == []
    end
  end

  # ── 黄金链路（review ON，R22-R28） ---------------------------------------------

  describe "黄金链路（review ON）" do
    test "指派 → 内容 → 门禁 → 报告 → 审核 → 发布：全链落库与终态" do
      owner = Fixtures.platform_admin("s5-golden-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-golden-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      reviewer = Fixtures.register_user("s5-golden-reviewer")
      Fixtures.add_member(workspace, reviewer, [])

      {course, run} = course_with_prep(workspace, owner, %{title: "黄金链路"})

      # 读面：draft + 默认策略 + 未指派 + 实时门禁（无内容 → 违规非空）
      assert {:reply, _, _} =
               status_reply =
               GetPrepStatus.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      status = decode(status_reply)
      assert status["prep_state"] == "draft"
      assert status["policy"] == Prep.default_policy()
      assert status["assignee_user_id"] == nil
      assert status["tutor"] == nil
      assert status["version"] == run.version
      assert status["gate_violations"] != []

      # Owner 指派 tutor：draft → authoring
      assert {:reply, _, _} =
               assign_reply =
               AssignPrepTutor.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "tutor_user_id" => tutor.id
                 },
                 frame_for(owner)
               )

      assigned = decode(assign_reply)
      assert assigned["prep_state"] == "authoring"
      assert assigned["assignee_user_id"] == tutor.id

      # tutor 生产内容（首存 base_version 0 → version 1）
      assert {:reply, _, _} = save_content(tutor, workspace, course)

      # 提交质量检查：门禁过 → quality_check
      assert {:reply, _, _} =
               check_reply =
               SubmitPrepForCheck.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      checked = decode(check_reply)
      assert checked["passed"] == true
      assert checked["violations"] == []
      assert checked["prep_state"] == "quality_check"
      assert checked["draft_version"] == 1

      # 质量报告 85 ≥ 默认阈值 80 → review
      assert {:reply, _, _} =
               report_reply =
               SubmitPrepQualityReport.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "report" => %{
                     "score" => 85,
                     "summary" => "结构完整",
                     "findings" => [%{"severity" => "info", "message" => "可补充例子"}]
                   }
                 },
                 frame_for(tutor)
               )

      reported = decode(report_reply)
      assert reported["outcome"] == "review"
      assert reported["prep_state"] == "review"
      assert reported["threshold"] == 80
      assert reported["course_status"] == "draft"

      # 另一成员审核通过（reviewer-per-policy 未指定 = 任何成员；确认流两段）
      assert {:reply, _, _} =
               approve_reply =
               ApprovePrep.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(reviewer)
               )

      approve_payload = decode(approve_reply)
      assert approve_payload["status"] == "needs_confirmation"
      assert approve_payload["summary"] =~ course.id

      # 第一段无副作用
      assert Ash.get!(Course, course.id, authorize?: false).status == :draft

      confirmed = confirm!(reviewer, approve_payload["pending_id"])
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["prep_state"] == "published"
      assert confirmed["result"]["course_status"] == "open"

      # 终态：课程 open、run succeeded、facts 记发布与审核审计
      assert Ash.get!(Course, course.id, authorize?: false).status == :open
      final = reload_run(run, workspace)
      assert final.status == :succeeded
      assert final.facts["prep_state"] == "published"
      assert final.facts["published_by"] == reviewer.id
      assert final.facts["approved_by"] == reviewer.id
      assert final.facts["latest_quality_report"]["score"] == 85
      assert final.facts["latest_quality_report"]["outcome"] == "passed"
      assert final.facts["latest_quality_report"]["submitted_by"] == tutor.id
    end

    test "自审：策略指定 reviewer_user_id 为 tutor 本人 → tutor approve 放行" do
      owner = Fixtures.platform_admin("s5-self-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-self-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      {course, _run} = course_with_prep(workspace, owner, %{title: "自审"})

      # Owner 指定 reviewer = tutor（确认流）
      assert {:reply, _, _} =
               policy_reply =
               UpdatePrepPolicy.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "reviewer_user_id" => tutor.id
                 },
                 frame_for(owner)
               )

      policy_payload = decode(policy_reply)
      assert policy_payload["status"] == "needs_confirmation"
      policy_confirmed = confirm!(owner, policy_payload["pending_id"])
      assert policy_confirmed["result"]["policy"]["reviewer_user_id"] == tutor.id

      # tutor 认领 → 内容 → 门禁 → 报告（review_required 默认 true → review）
      assert {:reply, _, _} =
               ClaimPrepAuthoring.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      :ok = drive_to_quality_check(workspace, course, tutor)

      assert {:reply, _, _} = report_reply = submit_report(tutor, workspace, course, 85)
      assert decode(report_reply)["outcome"] == "review"

      # tutor 本人 approve（确认流）
      assert {:reply, _, _} =
               approve_reply =
               ApprovePrep.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      confirmed = confirm!(tutor, decode(approve_reply)["pending_id"])
      assert confirmed["result"]["prep_state"] == "published"
      assert Ash.get!(Course, course.id, authorize?: false).status == :open
    end
  end

  # ── review OFF：报告达标直接发布 -------------------------------------------------

  describe "review OFF 自动发布" do
    test "review_required=false：认领 → 门禁 → 报告达标 → 直接发布（无人工审核）" do
      owner = Fixtures.platform_admin("s5-auto-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-auto-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      {course, run} = course_with_prep(workspace, owner, %{title: "自动发布"})

      # 策略调整（确认流）：review_required false
      assert {:reply, _, _} =
               policy_reply =
               UpdatePrepPolicy.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "review_required" => false
                 },
                 frame_for(owner)
               )

      policy_payload = decode(policy_reply)
      assert policy_payload["summary"] =~ "review_required"
      # 第一段无副作用：生效策略仍是快照默认
      assert Prep.policy(prep_run!(course, workspace))["review_required"] == true

      policy_confirmed = confirm!(owner, policy_payload["pending_id"])
      assert policy_confirmed["result"]["policy"]["review_required"] == false
      assert policy_confirmed["result"]["prep_state"] == "draft"
      # 快照本体不可变：override 落 facts，input_snapshot 不动
      reloaded = reload_run(run, workspace)
      assert reloaded.input_snapshot["prep_policy"]["review_required"] == true
      assert reloaded.facts["prep_policy_override"]["review_required"] == false

      # tutor 认领 → authoring
      assert {:reply, _, _} =
               claim_reply =
               ClaimPrepAuthoring.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      claimed = decode(claim_reply)
      assert claimed["prep_state"] == "authoring"
      assert claimed["assignee_user_id"] == tutor.id

      :ok = drive_to_quality_check(workspace, course, tutor)

      # 报告 90 ≥ 80 且 review OFF → 直接发布
      assert {:reply, _, _} = report_reply = submit_report(tutor, workspace, course, 90)
      reported = decode(report_reply)
      assert reported["outcome"] == "published"
      assert reported["course_status"] == "open"

      assert Ash.get!(Course, course.id, authorize?: false).status == :open
      final = reload_run(run, workspace)
      assert final.status == :succeeded
      assert final.facts["prep_state"] == "published"
      assert final.facts["published_by"] == tutor.id
    end
  end

  # ── 门禁失败（R26）与 launch 教研门（R23） ---------------------------------------

  describe "门禁失败与 launch 教研门" do
    test "无内容草稿 → submit_for_check 不过，违规清单落 facts，保持 authoring" do
      owner = Fixtures.platform_admin("s5-gate-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-gate-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      {course, run} = course_with_prep(workspace, owner, %{title: "门禁失败"})

      assert {:reply, _, _} =
               ClaimPrepAuthoring.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      # 不存内容直接提交
      assert {:reply, _, _} =
               reply =
               SubmitPrepForCheck.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      payload = decode(reply)
      assert payload["passed"] == false
      assert payload["prep_state"] == "authoring"
      assert payload["draft_version"] == 0
      assert payload["violations"] == ["课程内容为空：尚无经 save_course_content 保存的内容草稿"]

      # 违规清单落 facts（get_prep_status 透出同一份）
      assert reload_run(run, workspace).facts["gate_violations"] == payload["violations"]
    end

    test "临时占位标题 → 门禁报标题违规（内容合规也不放行）" do
      owner = Fixtures.platform_admin("s5-gate-title")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-gate-title-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      # 无 title 创建 → 系统占位标题 + provisional_title（S3 R21）
      {course, _run} = course_with_prep(workspace, owner, %{title: nil})
      assert course.provisional_title == true

      assert {:reply, _, _} =
               ClaimPrepAuthoring.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      assert {:reply, _, _} = save_content(tutor, workspace, course)

      assert {:reply, _, _} =
               reply =
               SubmitPrepForCheck.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(tutor)
               )

      payload = decode(reply)
      assert payload["passed"] == false
      assert payload["prep_state"] == "authoring"

      assert payload["violations"] == [
               "课程标题仍是系统生成的临时标题：请先经 update_course 设置正式标题"
             ]
    end

    test "launch 域 action 被拒：存在未走完的 prep run（带外发布拦截，域名层）" do
      owner = Fixtures.platform_admin("s5-launch-owner")
      workspace = Fixtures.create_workspace(owner)
      {course, _run} = course_with_prep(workspace, owner, %{title: "教研门"})

      assert {:error, %Ash.Error.Invalid{} = err} =
               course
               |> Ash.Changeset.for_update(:launch, %{}, tenant: workspace.id, actor: owner)
               |> Ash.update(tenant: workspace.id, actor: owner)

      assert Exception.message(err) =~ "课程须完成教研流程后发布"
      assert Ash.get!(Course, course.id, authorize?: false).status == :draft
    end

    test "MCP launch_course confirm 段同被教研门拦截（pending 回滚、课程仍 draft）" do
      owner = Fixtures.platform_admin("s5-launch-mcp")
      workspace = Fixtures.create_workspace(owner)
      {course, _run} = course_with_prep(workspace, owner, %{title: "教研门 MCP"})

      # 第一段：draft 快速预检通过，建 pending（教研门在域 action，confirm 段拦截）
      assert {:reply, _, _} =
               reply =
               LaunchCourse.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(owner)
               )

      payload = decode(reply)
      assert payload["status"] == "needs_confirmation"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               confirm(owner, payload["pending_id"])

      assert msg =~ "课程须完成教研流程后发布"
      assert Ash.get!(Course, course.id, authorize?: false).status == :draft
    end
  end

  # ── PrepGate 纯函数（R26；空 goals 内容无法入库，纯函数覆盖） --------------------

  describe "PrepGate 纯函数" do
    test "无内容 / 临时标题 / 空 goals / 空 issues / 形状非法逐条报违规" do
      course = %Course{provisional_title: false}
      provisional = %Course{provisional_title: true}

      valid_issue = %{
        "id" => "i1",
        "kind" => "handwork",
        "title" => "卡",
        "story" => %{"checklist" => [%{"id" => "c1", "text" => "项"}]}
      }

      # 无内容
      assert %{passed: false, violations: [msg]} = PrepGate.check(course, nil)
      assert msg =~ "内容为空"

      # 临时标题 + 无内容 → 两条
      assert %{passed: false, violations: [title_msg, content_msg]} =
               PrepGate.check(provisional, nil)

      assert title_msg =~ "临时标题"
      assert content_msg =~ "内容为空"

      # 空 goals（issues 合规）→ 仅 goals 违规（形状复核在 goals/issues 均非空时才做）
      output = %Output{data: %{"goals" => [], "issues" => [valid_issue]}}

      assert %{passed: false, violations: [goals_msg]} = PrepGate.check(course, output)
      assert goals_msg =~ "goals"

      # 空 issues → 仅 issues 违规
      output = %Output{data: %{"goals" => ["目标"], "issues" => []}}

      assert %{passed: false, violations: [issues_msg]} = PrepGate.check(course, output)
      assert issues_msg =~ "issue 卡集为空"

      # 形状非法（issue id 卡集内重复）→ 形状违规
      dup = %{valid_issue | "title" => "另一卡"}
      output = %Output{data: %{"goals" => ["目标"], "issues" => [valid_issue, dup]}}

      assert %{passed: false, violations: [shape_msg]} = PrepGate.check(course, output)
      assert shape_msg =~ "结构不合法"

      # 全部合规 → 通过
      output = %Output{data: %{"goals" => ["目标"], "issues" => [valid_issue]}}
      assert %{passed: true, violations: []} = PrepGate.check(course, output)
    end
  end

  # ── 低于阈值与覆盖（R27/AE5） ---------------------------------------------------

  describe "低于阈值与覆盖" do
    test "低于阈值 → 回 authoring + below_threshold_pending；带理由覆盖（确认流）→ review → 发布" do
      owner = Fixtures.platform_admin("s5-ovr-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-ovr-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      reviewer = Fixtures.register_user("s5-ovr-reviewer")
      Fixtures.add_member(workspace, reviewer, [])

      {course, run} = course_with_prep(workspace, owner, %{title: "覆盖链路"})

      {:ok, _run} = Prep.assign_tutor(run, tutor.id, owner)
      :ok = drive_to_quality_check(workspace, course, tutor)

      # 报告 50 < 80 → 回 authoring，待覆盖报告落 facts
      assert {:reply, _, _} = report_reply = submit_report(tutor, workspace, course, 50)
      reported = decode(report_reply)
      assert reported["outcome"] == "below_threshold"
      assert reported["prep_state"] == "authoring"
      assert reported["course_status"] == "draft"

      below = reload_run(run, workspace)
      assert below.facts["below_threshold_pending"]["score"] == 50
      assert below.facts["latest_quality_report"]["outcome"] == "below_threshold"

      # reviewer（默认策略：任何成员可审）带理由覆盖（确认流）→ review
      assert {:reply, _, _} =
               override_reply =
               OverridePrepGate.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "reason" => "线下评审已通过"
                 },
                 frame_for(reviewer)
               )

      override_payload = decode(override_reply)
      assert override_payload["status"] == "needs_confirmation"
      assert override_payload["summary"] =~ "线下评审已通过"
      assert override_payload["summary"] =~ "review"

      # 第一段无副作用
      assert Prep.prep_state(reload_run(run, workspace)) == "authoring"

      override_confirmed = confirm!(reviewer, override_payload["pending_id"])
      assert override_confirmed["result"]["outcome"] == "review"
      assert override_confirmed["result"]["prep_state"] == "review"

      overridden = reload_run(run, workspace)
      assert overridden.facts["gate_override"]["reason"] == "线下评审已通过"
      assert overridden.facts["gate_override"]["overridden_by"] == reviewer.id
      assert overridden.facts["below_threshold_pending"] == nil

      # 审核通过 → 发布
      assert {:reply, _, _} =
               approve_reply =
               ApprovePrep.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id},
                 frame_for(reviewer)
               )

      approve_confirmed = confirm!(reviewer, decode(approve_reply)["pending_id"])
      assert approve_confirmed["result"]["prep_state"] == "published"
      assert Ash.get!(Course, course.id, authorize?: false).status == :open
      assert reload_run(run, workspace).status == :succeeded
    end

    test "覆盖无理由 → error 不建 pending；无待覆盖报告 → error" do
      owner = Fixtures.platform_admin("s5-ovr-neg")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-ovr-neg-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      {course, run} = course_with_prep(workspace, owner, %{title: "覆盖负例"})

      {:ok, _run} = Prep.assign_tutor(run, tutor.id, owner)
      :ok = drive_to_quality_check(workspace, course, tutor)
      assert {:reply, _, _} = submit_report(tutor, workspace, course, 50)

      # 无理由（空串/空白同样拒）
      for reason <- ["", "   "] do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 OverridePrepGate.execute(
                   %{
                     "workspace_id" => workspace.id,
                     "course_id" => course.id,
                     "reason" => reason
                   },
                   frame_for(owner)
                 )

        assert msg =~ "reason is required"
      end

      assert pending_count() == 0

      # 覆盖成功（review ON → review 态，below_threshold_pending 清除）
      assert {:reply, _, _} =
               override_reply =
               OverridePrepGate.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "reason" => "达标证据线下补充"
                 },
                 frame_for(owner)
               )

      confirm!(owner, decode(override_reply)["pending_id"])
      assert Prep.prep_state(reload_run(run, workspace)) == "review"

      # 再次覆盖：无待覆盖报告 → 第一段快速失败（不建 pending）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               OverridePrepGate.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "reason" => "二次覆盖"
                 },
                 frame_for(owner)
               )

      assert msg =~ "no below-threshold quality report pending override"

      # 唯一 pending 行来自成功覆盖（confirmed 留痕）；二次覆盖第一段拒绝未新增
      assert pending_count() == 1

      assert Ash.get!(PendingOperation, decode(override_reply)["pending_id"], authorize?: false).status ==
               :confirmed
    end
  end

  # ── 认领竞态（R24；unboxed 真实事务 + Barrier，draft_versioning_test 同款纪律） ---

  describe "认领竞态" do
    test "两 tutor 并发认领同一未指派 prep run → 恰一成一败，落库恰一份指派" do
      {owner, workspace, course, tutors} =
        unboxed(fn ->
          owner = Fixtures.platform_admin("s5-claim-owner")
          workspace = Fixtures.create_workspace(owner)
          definition = create_prep_definition(workspace, owner)
          course = draft_course(workspace, owner, %{title: "认领竞态"})

          {:ok, _run} =
            PrepInstantiator.launch(workspace.id, definition.id, %{
              "course_id" => course.id,
              "title" => course.title
            })

          tutors =
            for name <- ["s5-claim-a", "s5-claim-b"] do
              tutor = Fixtures.register_user(name)
              Fixtures.add_member(workspace, tutor, [:tutor])
              tutor
            end

          {owner, workspace, course, tutors}
        end)

      cleanup_on_exit(workspace.id, [owner | tutors])
      barrier = start_supervised!({Barrier, 2})

      results =
        tutors
        |> Enum.map(fn tutor ->
          Task.async(fn ->
            unboxed(fn ->
              Barrier.arrive(barrier)

              case ClaimPrepAuthoring.execute(
                     %{"workspace_id" => workspace.id, "course_id" => course.id},
                     frame_for(tutor)
                   ) do
                {:reply, response, _frame} ->
                  [content] = response.content
                  {:ok, Jason.decode!(content["text"])}

                {:error, %Anubis.MCP.Error{message: msg}, _frame} ->
                  {:error, msg}
              end
            end)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
      assert winner["prep_state"] == "authoring"
      winner_id = winner["assignee_user_id"]
      assert winner_id in Enum.map(tutors, & &1.id)

      {:error, loser_msg} = Enum.find(results, &match?({:error, _}, &1))
      assert loser_msg =~ "already claimed"

      # 落库恰一份指派（胜者），prep_state authoring
      unboxed(fn ->
        run = Prep.fetch_run(course.id, workspace.id)
        assert Prep.assignee(run) == winner_id
        assert Prep.prep_state(run) == "authoring"
      end)
    end
  end

  # ── 策略冻结（R22：提交后生效策略冻结） ------------------------------------------

  describe "策略冻结" do
    test "进入 quality_check 后 update_prep_policy 被拒（第一段与域层双重）" do
      owner = Fixtures.platform_admin("s5-freeze-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-freeze-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      {course, run} = course_with_prep(workspace, owner, %{title: "策略冻结"})

      {:ok, _run} = Prep.assign_tutor(run, tutor.id, owner)
      :ok = drive_to_quality_check(workspace, course, tutor)
      assert Prep.prep_state(prep_run!(course, workspace)) == "quality_check"

      # 第一段快速失败（不建 pending）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               UpdatePrepPolicy.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "review_required" => false
                 },
                 frame_for(owner)
               )

      assert msg =~ "frozen"
      assert pending_count() == 0

      # 域层兜底（confirm 段同款前置断言：pending 存活期内状态翻转的防线）
      assert {:error, domain_msg} =
               Prep.update_policy(
                 prep_run!(course, workspace),
                 %{"review_required" => false},
                 owner
               )

      assert domain_msg =~ "invalid prep_state transition"
    end
  end

  # ── request_changes（R28） ------------------------------------------------------

  describe "request_changes" do
    test "review → authoring 且理由落 change_requests；无理由拒" do
      owner = Fixtures.platform_admin("s5-rc-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-rc-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      reviewer = Fixtures.register_user("s5-rc-reviewer")
      Fixtures.add_member(workspace, reviewer, [])

      {course, run} = course_with_prep(workspace, owner, %{title: "请求修改"})

      {:ok, _run} = Prep.assign_tutor(run, tutor.id, owner)
      :ok = drive_to_quality_check(workspace, course, tutor)
      assert {:reply, _, _} = report_reply = submit_report(tutor, workspace, course, 88)
      assert decode(report_reply)["outcome"] == "review"

      # 无理由 → error（不落 facts）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               RequestChangesPrep.execute(
                 %{"workspace_id" => workspace.id, "course_id" => course.id, "reason" => " "},
                 frame_for(reviewer)
               )

      assert msg =~ "reason is required"
      assert Prep.prep_state(reload_run(run, workspace)) == "review"

      # 有理由 → 回 authoring，理由追加进 change_requests
      assert {:reply, _, _} =
               reply =
               RequestChangesPrep.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "course_id" => course.id,
                   "reason" => "补充先修说明"
                 },
                 frame_for(reviewer)
               )

      assert decode(reply)["prep_state"] == "authoring"

      reloaded = reload_run(run, workspace)

      assert [%{"reason" => "补充先修说明", "requested_by" => requested_by}] =
               reloaded.facts["change_requests"]

      assert requested_by == reviewer.id
      assert Ash.get!(Course, course.id, authorize?: false).status == :draft
    end
  end

  # ── list_my_tasks 教研行（R20） --------------------------------------------------

  describe "list_my_tasks 教研行" do
    test "三类教研行按角色分派：claimable / authoring / review；plain member 不见" do
      owner = Fixtures.platform_admin("s5-tasks-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor_a = Fixtures.register_user("s5-tasks-tutor-a")
      Fixtures.add_member(workspace, tutor_a, [:tutor])
      tutor_b = Fixtures.register_user("s5-tasks-tutor-b")
      Fixtures.add_member(workspace, tutor_b, [:tutor])
      reviewer = Fixtures.register_user("s5-tasks-reviewer")
      Fixtures.add_member(workspace, reviewer, [])
      member = Fixtures.register_user("s5-tasks-member")
      Fixtures.add_member(workspace, member, [])

      definition = create_prep_definition(workspace, owner)

      # course_claimable：draft 未指派
      course_c = draft_course(workspace, owner, %{title: "待认领"})

      {:ok, _run_c} =
        PrepInstantiator.launch(workspace.id, definition.id, %{
          "course_id" => course_c.id,
          "title" => course_c.title
        })

      # course_authoring：指派 tutor_a（authoring）
      course_a = draft_course(workspace, owner, %{title: "生产中"})

      {:ok, run_a} =
        PrepInstantiator.launch(workspace.id, definition.id, %{
          "course_id" => course_a.id,
          "title" => course_a.title
        })

      {:ok, _run_a} = Prep.assign_tutor(run_a, tutor_a.id, owner)

      # course_review：指定 reviewer，推进到 review
      course_r = draft_course(workspace, owner, %{title: "待审核"})

      {:ok, run_r} =
        PrepInstantiator.launch(workspace.id, definition.id, %{
          "course_id" => course_r.id,
          "title" => course_r.title
        })

      {:ok, run_r} = Prep.update_policy(run_r, %{"reviewer_user_id" => reviewer.id}, owner)
      {:ok, run_r} = Prep.assign_tutor(run_r, tutor_a.id, owner)
      {:reply, _, _} = save_content(tutor_a, workspace, course_r)
      {:ok, run_r, %{passed: true}} = Prep.submit_for_check(run_r, tutor_a)

      {:ok, _run_r, :review} =
        Prep.submit_quality_report(run_r, tutor_a, %{"score" => 88, "summary" => "达标"})

      list = fn user ->
        {:reply, _, _} =
          reply = ListMyTasks.execute(%{"workspace_id" => workspace.id}, frame_for(user))

        decode(reply)["tasks"]
      end

      # tutor_b（tutor 角色、未指派）：只见 claimable
      assert [%{"kind" => "course_prep_claimable"} = row] = list.(tutor_b)
      assert row["course_id"] == course_c.id
      assert row["prep_state"] == "draft"
      assert row["context_title"] == "待认领"
      assert row["workspace_slug"] == workspace.slug

      # tutor_a：claimable（course_c）+ authoring（course_a）；course_r 已进
      # review 且 reviewer 指定他人 → 不见
      kinds_a = Map.new(list.(tutor_a), &{&1["course_id"], &1["kind"]})

      assert kinds_a == %{
               course_c.id => "course_prep_claimable",
               course_a.id => "course_prep_authoring"
             }

      # reviewer（指定 reviewer 仅本人）：review 行
      assert [%{"kind" => "course_prep_review", "course_id" => cid, "prep_state" => "review"}] =
               list.(reviewer)

      assert cid == course_r.id

      # owner（manage）：claimable + review；authoring 不见（非 assignee）
      kinds_o = Map.new(list.(owner), &{&1["course_id"], &1["kind"]})

      assert kinds_o == %{
               course_c.id => "course_prep_claimable",
               course_r.id => "course_prep_review"
             }

      # plain member（无 tutor/manage、非 assignee、reviewer 指定他人）：什么都不见
      assert list.(member) == []
    end
  end

  # ── 授权矩阵（九工具 × 负例角色） + ToolCallLog -----------------------------------

  describe "授权矩阵与 ToolCallLog" do
    test "plain member/learner/outsider 各拒；get_prep_status 成员可读、outsider 拒" do
      owner = Fixtures.platform_admin("s5-authz-owner")
      workspace = Fixtures.create_workspace(owner)
      tutor = Fixtures.register_user("s5-authz-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      reviewer = Fixtures.register_user("s5-authz-reviewer")
      Fixtures.add_member(workspace, reviewer, [])
      member = Fixtures.register_user("s5-authz-member")
      Fixtures.add_member(workspace, member, [])
      learner = Fixtures.register_user("s5-authz-learner")
      Fixtures.add_member(workspace, learner, [:learner])
      outsider = Fixtures.register_user("s5-authz-outsider")

      {course, run} = course_with_prep(workspace, owner, %{title: "授权矩阵"})

      # 布置：指定 reviewer（reviewer 族三工具的 member 负例前置）+ 指派 tutor
      # （submit 族两工具的非 assignee 负例前置）
      {:ok, run} = Prep.update_policy(run, %{"reviewer_user_id" => reviewer.id}, owner)
      {:ok, _run} = Prep.assign_tutor(run, tutor.id, owner)

      base = %{"workspace_id" => workspace.id, "course_id" => course.id}

      params_for = fn
        "assign_prep_tutor" ->
          Map.put(base, "tutor_user_id", tutor.id)

        "update_prep_policy" ->
          Map.put(base, "quality_threshold", 60)

        "submit_prep_quality_report" ->
          Map.put(base, "report", %{"score" => 50, "summary" => "x"})

        "override_prep_gate" ->
          Map.put(base, "reason", "理由")

        "request_changes_prep" ->
          Map.put(base, "reason", "改")

        _ ->
          base
      end

      expected_for = fn
        "get_prep_status" -> :member_readable
        "assign_prep_tutor" -> "owner or admin required"
        "claim_prep_authoring" -> "tutor, owner or admin required"
        "update_prep_policy" -> "owner or admin required"
        "submit_prep_for_check" -> "assigned tutor, owner or admin required"
        "submit_prep_quality_report" -> "assigned tutor, owner or admin required"
        "override_prep_gate" -> "reviewer-per-policy, owner or admin required"
        "approve_prep" -> "reviewer-per-policy, owner or admin required"
        "request_changes_prep" -> "reviewer-per-policy, owner or admin required"
      end

      for {tool_name, module} <- @tool_modules do
        params = params_for.(tool_name)

        case expected_for.(tool_name) do
          :member_readable ->
            # 读面：任何成员（含 learner）放行；outsider 撞 member 门
            for user <- [member, learner] do
              assert {:reply, _, _} = apply(module, :execute, [params, frame_for(user)]),
                     "expected #{tool_name} readable for #{user.email}"
            end

            assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                     apply(module, :execute, [params, frame_for(outsider)])

            assert msg =~ "not a member"
            [log] = tool_logs_for(outsider.id, tool_name)
            assert log.result_status == :forbidden

          fragment ->
            for {user, expected} <- [
                  {member, fragment},
                  {learner, fragment},
                  {outsider, "not a member"}
                ] do
              assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                       apply(module, :execute, [params, frame_for(user)]),
                     "expected #{tool_name} to reject #{user.email}"

              assert msg =~ "forbidden", "expected forbidden for #{tool_name}, got: #{msg}"

              assert msg =~ expected,
                     "expected #{inspect(expected)} for #{tool_name}, got: #{msg}"

              [log] = tool_logs_for(user.id, tool_name)
              assert log.result_status == :forbidden
            end
        end
      end

      # 负例全部第一段拒绝：无任何 pending 副作用
      assert pending_count() == 0
    end
  end

  # ── 私有布置（unboxed 清理；draft_versioning_test 同款） --------------------------

  defp cleanup_on_exit(workspace_id, users) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM mcp_tool_call_logs WHERE user_id = ANY($1)", [
          Enum.map(users, &Ecto.UUID.dump!(&1.id))
        ])

        Repo.query!("DELETE FROM curriculum_outputs WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Repo.query!("DELETE FROM courses WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Repo.query!("DELETE FROM workflow_runs WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN " <>
            "(SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Ecto.UUID.dump!(workspace_id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Ecto.UUID.dump!(workspace_id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Ecto.UUID.dump!(workspace_id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
