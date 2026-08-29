defmodule Cgc2046.Mcp.LearningLoopToolsTest do
  @moduledoc """
  学习循环三工具测试(S8,R36/R39-R44;S9 复习到期队列不随 S8（review_queue 恒缺席）):
  start_learning_run / submit_learning_attempt / get_learning_state 直调
  (不经 MCP 传输层,Frame 注入 current_user,与 course_tools_test 同款 pattern)。

  覆盖:
  - start:授权(仅 confirmed 学员)/ 无 published revision 拒 / 幂等
    (同 revision 重进 created=false)/ 发布新版后开新 run
  - submit:无 active run / rubric 精确覆盖 / confidence 范围 / evidence·rationale
    非空 / objective 存在性 / R41 先修锁 / qualifying 掌握投影 + 即时完成判定
    (不等 worker)/ 无限重试写新行(不可变账本)
  - get_learning_state:全形状 / stale_revision(run 绑旧版)/ 授权三层
    (成员 ∪ confirmed enrollment ∪ run 持有者)
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Learning.Runs
  alias Cgc2046.Mcp.ToolCallLog

  alias Cgc2046.Mcp.Tools.{
    AdminListAuditLogs,
    GetLearningState,
    StartLearningRun,
    SubmitLearningAttempt
  }

  alias Cgc2046.Workflows.WorkflowDefinition

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  # obj-run(必修,无先修)/ obj-explain(必修,先修 obj-run)/ obj-vars(选修)
  defp content_fixture do
    %{
      "goals" => ["能写程序"],
      "issues" => [
        %{
          "id" => "py-first",
          "kind" => "handwork",
          "title" => "第一个程序",
          "story" => %{"as_a" => "学员", "given" => [], "goal" => "独立写问候程序"},
          "objectives" => [
            %{
              "id" => "obj-run",
              "title" => "能运行问候程序",
              "required" => true,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "程序能运行"}]
            },
            %{
              "id" => "obj-explain",
              "title" => "能讲懂代码",
              "required" => true,
              "prereq_ids" => ["obj-run"],
              "rubric" => [%{"id" => "r1", "text" => "能逐行讲清"}]
            }
          ]
        },
        %{
          "id" => "py-vars",
          "kind" => "thoughtwork",
          "title" => "变量与数据",
          "story" => %{"as_a" => "学员", "given" => ["py-first"], "goal" => "理解变量绑定"},
          "objectives" => [
            %{
              "id" => "obj-vars",
              "title" => "能解释变量绑定",
              "required" => false,
              "prereq_ids" => [],
              "rubric" => [%{"id" => "r1", "text" => "能解释绑定"}]
            }
          ]
        }
      ]
    }
  end

  # 学员侧完整布景:workspace + course + published revision(绑定当前)+
  # published learning 定义 + confirmed enrollment
  defp learning_ctx(prefix) do
    admin = Fixtures.platform_admin(prefix)
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin, %{title: "Python 入门"})
    learner = Fixtures.register_user("#{prefix}-learner")
    enrollment = enroll(course, learner)
    revision = publish_revision(workspace, course, 1, content_fixture())
    definition = create_learning_definition(workspace, admin)

    %{
      admin: admin,
      workspace: workspace,
      course: course,
      learner: learner,
      enrollment: enrollment,
      revision: revision,
      definition: definition
    }
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: learner.id})
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
  end

  defp create_learning_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "学习 workflow",
          type: :learning,
          input_schema: %{},
          node_def: %{"steps" => [%{"id" => "learning_loop", "type" => "manual"}]}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  defp publish_revision(workspace, course, number, content) do
    {:ok, revision} =
      CourseRevision
      |> Ash.Changeset.for_create(
        :create,
        %{
          course_id: course.id,
          number: number,
          content: content,
          published_at: DateTime.utc_now()
        },
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    course
    |> Ash.Changeset.for_update(:bind_current_revision, %{current_revision_id: revision.id},
      tenant: workspace.id
    )
    |> Ash.update!(tenant: workspace.id, authorize?: false)

    revision
  end

  defp start(ctx, actor) do
    StartLearningRun.execute(
      %{"workspace_id" => ctx.workspace.id, "course_id" => ctx.course.id},
      frame_for(actor)
    )
  end

  defp submit(ctx, actor, objective_id, overrides \\ %{}) do
    SubmitLearningAttempt.execute(
      Map.merge(
        %{
          "workspace_id" => ctx.workspace.id,
          "course_id" => ctx.course.id,
          "objective_id" => objective_id,
          "evidence" => "实机跑通,输出正确",
          "rubric_results" => [%{"criterion_id" => "r1", "met" => true}],
          "passed" => true,
          "rationale" => "证据可复核,标准达成",
          "confidence" => 0.9
        },
        overrides
      ),
      frame_for(actor)
    )
  end

  defp get_state(ctx, actor) do
    GetLearningState.execute(
      %{"workspace_id" => ctx.workspace.id, "course_id" => ctx.course.id},
      frame_for(actor)
    )
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(Cgc2046.Workflows.WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  describe "start_learning_run(R36)" do
    test "未报名 → forbidden;无 published revision → 明确错误" do
      ctx = learning_ctx("ll-start-auth")
      outsider = Fixtures.register_user("ll-start-auth-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} = start(ctx, outsider)
      assert msg =~ "forbidden"

      # 无 revision 的课程:已报名也拒(教研未完成)
      admin = Fixtures.platform_admin("ll-start-norev")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "无版本课"})
      learner = Fixtures.register_user("ll-start-norev-learner")
      _enrollment = enroll(course, learner)

      bare_ctx = %{workspace: workspace, course: course}

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               StartLearningRun.execute(
                 %{"workspace_id" => bare_ctx.workspace.id, "course_id" => bare_ctx.course.id},
                 frame_for(learner)
               )

      assert msg2 =~ "no published revision"
    end

    test "启动成功 created=true + running + revision 绑定;重复启动幂等(created=false 同 run)" do
      ctx = learning_ctx("ll-start-ok")

      assert {:reply, _, _} = reply = start(ctx, ctx.learner)
      payload = decode(reply)

      assert payload["created"] == true
      assert payload["status"] == "running"
      assert payload["revision_id"] == ctx.revision.id
      assert payload["revision_number"] == 1

      run = fetch_run(payload["run_id"], ctx.workspace.id)
      assert run.input_snapshot["course_revision_id"] == ctx.revision.id
      assert run.input_snapshot["key"] == Runs.instance_key(ctx.enrollment.id, ctx.revision.id)

      assert {:reply, _, _} = again = start(ctx, ctx.learner)
      again_payload = decode(again)
      assert again_payload["created"] == false
      assert again_payload["run_id"] == payload["run_id"]
    end

    test "发布新 revision 后再启动 → 新 run(版本 key 变化)" do
      ctx = learning_ctx("ll-start-v2")

      assert {:reply, _, _} = first = start(ctx, ctx.learner)
      first_payload = decode(first)

      revision_2 = publish_revision(ctx.workspace, ctx.course, 2, content_fixture())

      assert {:reply, _, _} = second = start(ctx, ctx.learner)
      second_payload = decode(second)

      assert second_payload["created"] == true
      assert second_payload["run_id"] != first_payload["run_id"]
      assert second_payload["revision_id"] == revision_2.id
      assert second_payload["revision_number"] == 2
    end
  end

  describe "submit_learning_attempt 校验链(R41-R44)" do
    test "无 active run → 提示先 start_learning_run" do
      ctx = learning_ctx("ll-submit-norun")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} = submit(ctx, ctx.learner, "obj-run")
      assert msg =~ "no active learning run"
      assert msg =~ "start_learning_run"
    end

    test "objective 不存在 → 报 known ids;rubric 不精确覆盖 → 报 expected/got" do
      ctx = learning_ctx("ll-submit-validate")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      assert {:error, %Anubis.MCP.Error{message: msg1}, _} = submit(ctx, ctx.learner, "obj-ghost")
      assert msg1 =~ "not found"
      assert msg1 =~ "obj-run"

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               submit(ctx, ctx.learner, "obj-run", %{
                 "rubric_results" => [%{"criterion_id" => "wrong", "met" => true}]
               })

      assert msg2 =~ "rubric_results must cover exactly"
      assert msg2 =~ "expected"
      assert msg2 =~ "wrong"
    end

    test "confidence 越界 / evidence / rationale 空 → 明确错误" do
      ctx = learning_ctx("ll-submit-fields")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      assert {:error, %Anubis.MCP.Error{message: msg1}, _} =
               submit(ctx, ctx.learner, "obj-run", %{"confidence" => 1.5})

      assert msg1 =~ "confidence must be a number in 0..1"

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               submit(ctx, ctx.learner, "obj-run", %{"evidence" => "  "})

      assert msg2 =~ "evidence must be non-empty"

      assert {:error, %Anubis.MCP.Error{message: msg3}, _} =
               submit(ctx, ctx.learner, "obj-run", %{"rationale" => ""})

      assert msg3 =~ "rationale must be non-empty"
    end

    test "R41 先修锁:锁定 objective 拒评,报缺失先修 id+title,不可绕过" do
      ctx = learning_ctx("ll-submit-lock")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               submit(ctx, ctx.learner, "obj-explain")

      assert msg =~ "locked"
      assert msg =~ "obj-run"
      assert msg =~ "能运行问候程序"

      # 先修 qualifying 后解锁
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run")
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-explain")
    end

    test "qualifying 提交 → mastered + 下一动作;全必修 qualifying → run_completed 且 run succeeded(即时)" do
      ctx = learning_ctx("ll-submit-flow")
      assert {:reply, _, _} = start_reply = start(ctx, ctx.learner)
      run_id = decode(start_reply)["run_id"]

      assert {:reply, _, _} = first = submit(ctx, ctx.learner, "obj-run")
      first_payload = decode(first)

      assert first_payload["mastery"] == "mastered"
      assert first_payload["ever_mastered"] == true
      assert first_payload["run_completed"] == false
      assert first_payload["next_action"]["kind"] == "next_required"
      assert first_payload["next_action"]["objective_id"] == "obj-explain"
      assert first_payload["next_action"]["reason"] =~ "能讲懂代码"

      assert {:reply, _, _} = second = submit(ctx, ctx.learner, "obj-explain")
      second_payload = decode(second)

      assert second_payload["run_completed"] == true
      # 完成守卫:不再推荐下一动作
      assert second_payload["next_action"] == nil

      assert fetch_run(run_id, ctx.workspace.id).status == :succeeded
    end

    test "失败后重试写新行(不可变账本,无限重试)" do
      ctx = learning_ctx("ll-submit-retry")
      assert {:reply, _, _} = start_reply = start(ctx, ctx.learner)
      run_id = decode(start_reply)["run_id"]

      # 失败 attempt(passed=false)→ developing
      assert {:reply, _, _} = failed = submit(ctx, ctx.learner, "obj-run", %{"passed" => false})
      assert decode(failed)["mastery"] == "developing"

      # 重试 qualifying → mastered;两行均在账本
      assert {:reply, _, _} = retried = submit(ctx, ctx.learner, "obj-run")
      retried_payload = decode(retried)
      assert retried_payload["mastery"] == "mastered"
      assert retried_payload["attempt_id"] != decode(failed)["attempt_id"]

      run = fetch_run(run_id, ctx.workspace.id)
      assert length(Runs.attempts_for(run)) == 2
    end

    test "审计收窄(S10,R48/AE12/AE13):ToolCallLog params 只留引用字段,证据正文不落审计" do
      ctx = learning_ctx("ll-submit-audit")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      assert {:reply, _, _} =
               submit(ctx, ctx.learner, "obj-run", %{
                 "evidence" => "EVIDENCE-MARKER-ll-audit-学员作答正文",
                 "rationale" => "RATIONALE-MARKER-ll-audit-判定理由正文",
                 "agent_meta" => %{"client" => "openclacky-test"}
               })

      [log] =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^ctx.learner.id and tool == "submit_learning_attempt")
        |> Ash.read!(authorize?: false)

      # 引用字段保留(含宽存 confidence/passed),证据/rubric 明细/理由/agent_meta 不落审计
      assert log.params == %{
               "workspace_id" => ctx.workspace.id,
               "course_id" => ctx.course.id,
               "objective_id" => "obj-run",
               "passed" => true,
               "confidence" => 0.9
             }

      refute Jason.encode!(log.params) =~ "EVIDENCE-MARKER"
      refute Jason.encode!(log.params) =~ "RATIONALE-MARKER"
      refute Jason.encode!(log.params) =~ "openclacky-test"
    end
  end

  describe "get_learning_state(R39/R40)" do
    test "全形状:run 摘要 + objectives 投影 + next_action + progress" do
      ctx = learning_ctx("ll-state-full")
      assert {:reply, _, _} = start_reply = start(ctx, ctx.learner)
      run_id = decode(start_reply)["run_id"]

      assert {:reply, _, _} = reply = get_state(ctx, ctx.learner)
      state = decode(reply)

      assert state["run"]["id"] == run_id
      assert state["run"]["status"] == "running"
      assert state["run"]["revision_number"] == 1
      assert state["revision_number"] == 1
      assert state["stale_revision"] == false

      objectives = state["objectives"]
      assert length(objectives) == 3

      [obj_run, obj_explain, obj_vars] = objectives
      assert obj_run["id"] == "obj-run"
      assert obj_run["mastery"] == "unassessed"
      assert obj_run["locked"] == false
      assert obj_run["attempt_count"] == 0
      assert obj_run["last_attempt_at"] == nil

      assert obj_explain["locked"] == true
      assert obj_explain["missing_prereq_ids"] == [%{"id" => "obj-run", "title" => "能运行问候程序"}]

      assert obj_vars["required"] == false

      assert state["next_action"]["kind"] == "next_required"
      assert state["next_action"]["objective_id"] == "obj-run"
      assert state["next_action"]["reason"] =~ "能运行问候程序"

      assert state["progress"] == %{
               "mastered_required" => 0,
               "total_required" => 2,
               "complete" => false
             }
    end

    test "stale_revision:run 绑 v1 发布 v2 后,投影报 run 自己的 v1 内容 + stale=true" do
      ctx = learning_ctx("ll-state-stale")
      assert {:reply, _, _} = start_reply = start(ctx, ctx.learner)
      run_id = decode(start_reply)["run_id"]

      # 提交 v1 的 obj-run qualifying
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run")

      # 发布 v2(objective id 全部换新)
      v2_content =
        put_in(content_fixture(), ["issues", Access.at(0), "objectives"], [
          %{
            "id" => "obj-v2",
            "title" => "新版目标",
            "required" => true,
            "prereq_ids" => [],
            "rubric" => [%{"id" => "r1", "text" => "新版"}]
          }
        ])

      _revision_2 = publish_revision(ctx.workspace, ctx.course, 2, v2_content)

      assert {:reply, _, _} = reply = get_state(ctx, ctx.learner)
      state = decode(reply)

      assert state["stale_revision"] == true
      # 课程当前版本号 = 2,run 绑定 = 1
      assert state["revision_number"] == 2
      assert state["run"]["id"] == run_id
      assert state["run"]["revision_number"] == 1

      # objectives 仍是 v1 的(run 学完旧版前不被换底),v1 掌握态保留
      ids = Enum.map(state["objectives"], & &1["id"])
      assert "obj-run" in ids
      refute "obj-v2" in ids
      assert Enum.find(state["objectives"], &(&1["id"] == "obj-run"))["mastery"] == "mastered"
    end

    test "授权:tutor 成员可读;outsider forbidden;run 持有者(cancel 后)可读" do
      ctx = learning_ctx("ll-state-auth")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      tutor = Fixtures.register_user("ll-state-auth-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])
      outsider = Fixtures.register_user("ll-state-auth-outsider")

      # tutor 成员读放行
      assert {:reply, _, _} = get_state(ctx, tutor)

      # outsider 拒
      assert {:error, %Anubis.MCP.Error{message: msg}, _} = get_state(ctx, outsider)
      assert msg =~ "forbidden"

      # 报名取消后(非 confirmed),run 持有者读仍放行(「曾学过」读面)
      [enrollment] =
        Enrollment
        |> Ash.Query.filter(course_id == ^ctx.course.id and user_id == ^ctx.learner.id)
        |> Ash.read!(authorize?: false)

      enrollment
      |> Ash.Changeset.for_update(:cancel, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert {:reply, _, _} = get_state(ctx, ctx.learner)
    end
  end

  describe "复习队列(R45,S9)" do
    test "fresh mastery:刚掌握的 objective 里程碑未到 → review_queue 为空" do
      ctx = learning_ctx("ll-review-fresh")
      assert {:reply, _, _} = start(ctx, ctx.learner)
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run")

      assert {:reply, _, _} = reply = get_state(ctx, ctx.learner)
      state = decode(reply)

      assert state["review_queue"] == []
      # 掌握后里程碑未到,next_action 正常推进下一必修
      assert state["next_action"]["kind"] == "next_required"
    end

    test "复习失败 → needs_review 立即到期入队(带 flag);next_action review 优先于 developing" do
      ctx = learning_ctx("ll-review-flip")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      # obj-run qualifying 掌握;随后复习失败 → needs_review
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run")

      assert {:reply, _, _} = failed = submit(ctx, ctx.learner, "obj-run", %{"passed" => false})
      failed_payload = decode(failed)
      assert failed_payload["mastery"] == "needs_review"
      assert failed_payload["ever_mastered"] == true
      # submit 响应的 next_action 同源:复习回补优先
      assert failed_payload["next_action"]["kind"] == "review"
      assert failed_payload["next_action"]["objective_id"] == "obj-run"
      assert failed_payload["next_action"]["reason"] =~ "待复习"

      # obj-explain 已解锁(obj-run ever_mastered 粘性),失败 → developing
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-explain", %{"passed" => false})

      assert {:reply, _, _} = reply = get_state(ctx, ctx.learner)
      state = decode(reply)

      # needs_review 恒立即到期:due_at = 失败 attempt 时间,下一里程碑 +1d
      assert [entry] = state["review_queue"]
      assert entry["objective_id"] == "obj-run"
      assert entry["needs_review"] == true
      assert entry["milestone_days"] == 1
      assert is_binary(entry["due_at"])

      # R40:review 优先于 developing(obj-explain)
      assert state["next_action"]["kind"] == "review"
      assert state["next_action"]["objective_id"] == "obj-run"
      assert state["next_action"]["reason"] =~ "待复习"
    end

    test "AE10:进行中 needs_review 翻转不撤销完成;完成后无复习提交通道(v1 边界,L4 已知代价)" do
      ctx = learning_ctx("ll-review-ae10")
      assert {:reply, _, _} = start_reply = start(ctx, ctx.learner)
      run_id = decode(start_reply)["run_id"]

      # obj-run 掌握后复习失败(进行中翻转 needs_review)→ 再完成 obj-explain
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run")
      assert {:reply, _, _} = submit(ctx, ctx.learner, "obj-run", %{"passed" => false})

      assert {:reply, _, _} = completed = submit(ctx, ctx.learner, "obj-explain")
      assert decode(completed)["run_completed"] == true
      assert fetch_run(run_id, ctx.workspace.id).status == :succeeded

      assert {:reply, _, _} = reply = get_state(ctx, ctx.learner)
      state = decode(reply)

      # AE10:完成不撤销——obj-run needs_review 仍 ever_mastered,完成判定不倒退
      assert state["progress"]["complete"] == true

      obj_run = Enum.find(state["objectives"], &(&1["id"] == "obj-run"))
      assert obj_run["mastery"] == "needs_review"
      assert obj_run["ever_mastered"] == true

      # 复习队列仍列出(被查看 run 的复习到期视图);完成守卫 → next_action = nil
      assert [%{"objective_id" => "obj-run", "needs_review" => true}] = state["review_queue"]
      assert state["next_action"] == nil

      # v1 边界:终态 run 无复习提交通道(submit 拒,提示先 start)
      assert {:error, %Anubis.MCP.Error{message: msg}, _} = submit(ctx, ctx.learner, "obj-run")
      assert msg =~ "no active learning run"

      # 同版重进 = resume 语义:返回既有完成 run,不开新 run
      assert {:reply, _, _} = again = start(ctx, ctx.learner)
      again_payload = decode(again)
      assert again_payload["created"] == false
      assert again_payload["run_id"] == run_id
      assert again_payload["status"] == "succeeded"
    end
  end

  describe "审计跨面组合(AE12×AE13,S10 终验)" do
    test "submit 带 marker → admin_list_audit_logs 读回全源无 marker" do
      ctx = learning_ctx("ll-audit-combo")
      assert {:reply, _, _} = start(ctx, ctx.learner)

      assert {:reply, _, _} =
               submit(ctx, ctx.learner, "obj-run", %{
                 "evidence" => "EVIDENCE-MARKER-combo-学员作答正文",
                 "rationale" => "RATIONALE-MARKER-combo-判定理由正文"
               })

      # 平台管理员经 admin_list_audit_logs 读 tool_calls 源:全库唯一审计写点
      admin = Fixtures.platform_admin("ll-audit-combo-admin")

      assert {:reply, _, _} =
               tc_reply =
               AdminListAuditLogs.execute(%{"source" => "tool_calls"}, frame_for(admin))

      tc = decode(tc_reply)
      assert Enum.any?(tc["logs"], &(&1["tool"] == "submit_learning_attempt"))

      raw = tc["logs"] |> Jason.encode!()

      refute raw =~ "EVIDENCE-MARKER"
      refute raw =~ "RATIONALE-MARKER"
      refute raw =~ "evidence"
      refute raw =~ "rationale"
    end
  end
end
