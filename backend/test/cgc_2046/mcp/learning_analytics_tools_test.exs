defmodule Cgc2046.Mcp.LearningAnalyticsToolsTest do
  @moduledoc """
  get_course_learning_analytics 工具测试(S10,R49/R50;AE12/AE13/AE14)。

  直调模式同 learning_loop_tools_test(Frame 注入 current_user);学习数据
  全部经真实工具链(start_learning_run / submit_learning_attempt)落库。

  覆盖:
  - 聚合正确性:掌握四态按 run 计 / 重试热点(total_attempts /
    avg_attempts_to_first_mastery)/ 低置信度计数(confidence < 0.8)/
    pass_rate / completion_rate / last_activity_at / generated_at
  - drop_off.stale_run_count:Runs 停滞口径同源(7 天),仅计非终态 run
    (完成 run 停滞不算流失),零 attempt run 回退 run.inserted_at
  - orphan_objectives:发布新版移除 objective 后,旧版 attempts 归 orphan
    汇总行;id 仍匹配的旧版 attempts 聚合到当前行(状态判定用 attempt
    所属 run 绑定 revision 的 rubric)
  - 授权矩阵:tutor ok / owner ok / plain member forbidden / outsider
    member-only 门 forbidden;每次调用落 ToolCallLog
  - R49 红线:响应 JSON 不含任何 evidence / rationale 正文(标记串扫描)
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Curriculum.CourseRevision
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Tools.{GetCourseLearningAnalytics, StartLearningRun, SubmitLearningAttempt}
  alias Cgc2046.Workflows.WorkflowDefinition

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp reply_parts({:reply, response, _frame}) do
    [content] = response.content
    {content["text"], Jason.decode!(content["text"])}
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

  defp learning_ctx(prefix) do
    admin = Fixtures.platform_admin(prefix)
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin, %{title: "Python 入门"})
    revision = publish_revision(workspace, course, 1, content_fixture())
    definition = create_learning_definition(workspace, admin)

    %{
      admin: admin,
      workspace: workspace,
      course: course,
      revision: revision,
      definition: definition
    }
  end

  defp enroll_learner(ctx, prefix, name) do
    learner = Fixtures.register_user("#{prefix}-#{name}")

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        course_id: ctx.course.id,
        user_id: learner.id
      })
      |> Ash.create(tenant: ctx.workspace.id, actor: learner)

    %{learner: learner, enrollment: enrollment}
  end

  defp create_learning_definition(workspace, actor) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "学习 workflow（测试布景）",
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

  defp analytics(ctx, actor) do
    GetCourseLearningAnalytics.execute(
      %{"workspace_id" => ctx.workspace.id, "course_id" => ctx.course.id},
      frame_for(actor)
    )
  end

  defp objective_row(payload, objective_id) do
    Enum.find(payload["objectives"], &(&1["objective_id"] == objective_id))
  end

  defp tool_logs_for(user_id, tool) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  # inserted_at / created_at 由资源 action 自动控制,SQL backdate 造停滞边界
  # (同 graphql_admin_queries_test 先例;UPDATE 恰命中一行)
  defp backdate(table, id, column, dt) do
    assert %{num_rows: 1} =
             Ecto.Adapters.SQL.query!(
               Cgc2046.Repo,
               "UPDATE #{table} SET #{column} = $1 WHERE id = $2",
               [dt, Ecto.UUID.dump!(id)]
             )
  end

  describe "聚合正确性(R49)" do
    test "四态按 run 计 + 重试热点 + 低置信度 + pass_rate + 完成率" do
      ctx = learning_ctx("la-main")
      tutor = Fixtures.register_user("la-main-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])

      %{learner: l1} = enroll_learner(ctx, "la-main", "l1")
      %{learner: l2} = enroll_learner(ctx, "la-main", "l2")
      %{learner: l3} = enroll_learner(ctx, "la-main", "l3")

      # l1:obj-run 一次 qualifying → mastered;obj-explain qualifying → run 完成
      assert {:reply, _, _} = start(ctx, l1)

      assert {:reply, _, _} =
               submit(ctx, l1, "obj-run", %{
                 "evidence" => "EVIDENCE-MARKER-la-main",
                 "rationale" => "RATIONALE-MARKER-la-main"
               })

      assert {:reply, _, _} = completed = submit(ctx, l1, "obj-explain")
      assert decode(completed)["run_completed"] == true

      # l2:obj-run 三次失败(0.5 / 0.7 低置信 + 0.9 未通过)后第四次 qualifying;
      # obj-explain 一次失败 → developing
      assert {:reply, _, _} = start(ctx, l2)

      assert {:reply, _, _} =
               submit(ctx, l2, "obj-run", %{"passed" => false, "confidence" => 0.5})

      assert {:reply, _, _} = submit(ctx, l2, "obj-run", %{"confidence" => 0.7})
      assert {:reply, _, _} = submit(ctx, l2, "obj-run", %{"passed" => false})
      assert {:reply, _, _} = submit(ctx, l2, "obj-run", %{"confidence" => 0.85})
      assert {:reply, _, _} = submit(ctx, l2, "obj-explain", %{"passed" => false})

      # l3:只评选修 obj-vars(qualifying);必修全 unassessed
      assert {:reply, _, _} = start(ctx, l3)
      assert {:reply, _, _} = submit(ctx, l3, "obj-vars")

      # l4:报名但从未启动 run——不进 run_stats
      %{learner: _l4} = enroll_learner(ctx, "la-main", "l4")

      assert {:reply, _, _} = reply = analytics(ctx, tutor)
      {_raw, payload} = reply_parts(reply)

      # run_stats:3 run(l1 完成 + l2/l3 进行中);l4 无 run 不计
      assert payload["run_stats"] == %{
               "total_runs" => 3,
               "active_runs" => 2,
               "completed_runs" => 1,
               "completion_rate" => Float.round(1 / 3, 4)
             }

      assert is_binary(payload["generated_at"])
      assert payload["drop_off"] == %{"stale_run_count" => 0}
      assert payload["orphan_objectives"]["total_attempts"] == 0
      assert payload["orphan_objectives"]["objective_ids"] == []

      # obj-run:l1 mastered / l2 mastered(4 次后)/ l3 unassessed
      obj_run = objective_row(payload, "obj-run")
      assert obj_run["title"] == "能运行问候程序"
      assert obj_run["required"] == true
      assert obj_run["mastered"] == 2
      assert obj_run["developing"] == 0
      assert obj_run["needs_review"] == 0
      assert obj_run["unassessed"] == 1
      # 重试热点:l1 1 次 + l2 4 次 = 5;qualifying = 各最后一次
      assert obj_run["total_attempts"] == 5
      assert obj_run["qualifying_passes"] == 2
      assert obj_run["pass_rate"] == 0.4
      # 低置信度:0.5 与 0.7 两条(0.85/0.9 不计)
      assert obj_run["low_confidence_attempts"] == 2
      # 平均首次掌握评价次数:(1 + 4) / 2
      assert obj_run["avg_attempts_to_first_mastery"] == 2.5
      assert is_binary(obj_run["last_activity_at"])

      # obj-explain:l1 mastered / l2 developing / l3 unassessed
      obj_explain = objective_row(payload, "obj-explain")
      assert obj_explain["mastered"] == 1
      assert obj_explain["developing"] == 1
      assert obj_explain["unassessed"] == 1
      assert obj_explain["total_attempts"] == 2
      assert obj_explain["qualifying_passes"] == 1
      assert obj_explain["pass_rate"] == 0.5
      assert obj_explain["low_confidence_attempts"] == 0
      assert obj_explain["avg_attempts_to_first_mastery"] == 1.0

      # obj-vars:选修,l3 mastered;l1/l2 未评
      obj_vars = objective_row(payload, "obj-vars")
      assert obj_vars["required"] == false
      assert obj_vars["mastered"] == 1
      assert obj_vars["unassessed"] == 2
      assert obj_vars["total_attempts"] == 1
      assert obj_vars["avg_attempts_to_first_mastery"] == 1.0
    end

    test "无人掌握的 objective:avg_attempts_to_first_mastery 与零 attempt 的 pass_rate 为 null" do
      ctx = learning_ctx("la-nulls")
      tutor = Fixtures.register_user("la-nulls-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])

      assert {:reply, _, _} = reply = analytics(ctx, tutor)
      {_raw, payload} = reply_parts(reply)

      # 零 run:completion_rate 不除零 → null
      assert payload["run_stats"]["total_runs"] == 0
      assert payload["run_stats"]["completion_rate"] == nil

      obj_run = objective_row(payload, "obj-run")
      assert obj_run["total_attempts"] == 0
      assert obj_run["pass_rate"] == nil
      assert obj_run["avg_attempts_to_first_mastery"] == nil
      assert obj_run["last_activity_at"] == nil
    end

    test "R49 红线:响应 JSON 不含 evidence / rationale 正文(标记串扫描)" do
      ctx = learning_ctx("la-redline")
      tutor = Fixtures.register_user("la-redline-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])

      %{learner: learner} = enroll_learner(ctx, "la-redline", "l1")
      assert {:reply, _, _} = start(ctx, learner)

      assert {:reply, _, _} =
               submit(ctx, learner, "obj-run", %{
                 "evidence" => "EVIDENCE-MARKER-la-redline-学员作答正文",
                 "rationale" => "RATIONALE-MARKER-la-redline-判定理由正文"
               })

      assert {:reply, _, _} = reply = analytics(ctx, tutor)
      {raw, _payload} = reply_parts(reply)

      refute raw =~ "EVIDENCE-MARKER"
      refute raw =~ "RATIONALE-MARKER"
      refute raw =~ "实机跑通"
      refute raw =~ "evidence"
      refute raw =~ "rationale"
    end
  end

  describe "orphan_objectives 汇总(旧版移除 objective)" do
    test "id 匹配的旧版 attempts 聚合到当前行;被移除 objective 归 orphan 汇总" do
      ctx = learning_ctx("la-orphan")
      tutor = Fixtures.register_user("la-orphan-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])

      %{learner: learner} = enroll_learner(ctx, "la-orphan", "l1")
      assert {:reply, _, _} = start(ctx, learner)
      assert {:reply, _, _} = submit(ctx, learner, "obj-run")
      assert {:reply, _, _} = submit(ctx, learner, "obj-vars")

      # 发布 v2:保 obj-run(同 id),移除 obj-vars 与 obj-explain,新增 obj-new
      v2_content = %{
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
                "title" => "能运行问候程序 v2",
                "required" => true,
                "prereq_ids" => [],
                "rubric" => [%{"id" => "r1", "text" => "程序能运行"}]
              },
              %{
                "id" => "obj-new",
                "title" => "新版选修",
                "required" => false,
                "prereq_ids" => [],
                "rubric" => [%{"id" => "r1", "text" => "新版"}]
              }
            ]
          }
        ]
      }

      publish_revision(ctx.workspace, ctx.course, 2, v2_content)

      assert {:reply, _, _} = reply = analytics(ctx, tutor)
      {_raw, payload} = reply_parts(reply)

      # 当前行只有 v2 objectives
      assert Enum.map(payload["objectives"], & &1["objective_id"]) |> Enum.sort() ==
               ["obj-new", "obj-run"]

      # obj-run:id 匹配——v1 的 qualifying attempt 聚合到当前行
      # (状态判定用 run 绑定 v1 的 rubric;rubric 同 id,qualifying 成立)
      obj_run = objective_row(payload, "obj-run")
      assert obj_run["title"] == "能运行问候程序 v2"
      assert obj_run["mastered"] == 1
      assert obj_run["total_attempts"] == 1
      assert obj_run["qualifying_passes"] == 1

      # obj-new:run 绑 v1 不含此 objective——不计入任何状态
      obj_new = objective_row(payload, "obj-new")
      assert obj_new["mastered"] == 0
      assert obj_new["unassessed"] == 0
      assert obj_new["total_attempts"] == 0

      # obj-vars(v2 已移除)→ orphan 汇总行
      orphan = payload["orphan_objectives"]
      assert orphan["objective_ids"] == ["obj-vars"]
      assert orphan["total_attempts"] == 1
      assert is_binary(orphan["last_activity_at"])

      # v1 必修 = obj-run + obj-explain(obj-explain 未评)→ run 仍 running,
      # 不受 orphan 影响
      assert payload["run_stats"]["completed_runs"] == 0
      assert payload["run_stats"]["active_runs"] == 1
    end
  end

  describe "drop_off.stale_run_count(R50 口径同源)" do
    test "7 天无活动的非终态 run 计入;完成 run 与新鲜 run 不计" do
      ctx = learning_ctx("la-stale")
      tutor = Fixtures.register_user("la-stale-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])
      eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

      # s1:掌握 obj-run 后停滞(obj-explain 未评,run 仍 running)
      %{learner: s1} = enroll_learner(ctx, "la-stale", "s1")
      assert {:reply, _, _} = start(ctx, s1)
      assert {:reply, _, _} = submit_reply = submit(ctx, s1, "obj-run")
      attempt_id = decode(submit_reply)["attempt_id"]
      backdate("learning_attempts", attempt_id, "created_at", eight_days_ago)

      # s2:零 attempt run,backdate run.inserted_at
      %{learner: s2} = enroll_learner(ctx, "la-stale", "s2")
      assert {:reply, _, _} = s2_reply = start(ctx, s2)
      s2_run_id = decode(s2_reply)["run_id"]
      backdate("workflow_runs", s2_run_id, "inserted_at", eight_days_ago)

      # s3:完成的 run 即使全 backdate 也不算流失(非终态才计)
      %{learner: s3} = enroll_learner(ctx, "la-stale", "s3")
      assert {:reply, _, _} = s3_start = start(ctx, s3)
      assert {:reply, _, _} = s3_a1 = submit(ctx, s3, "obj-run")
      assert {:reply, _, _} = s3_a2 = submit(ctx, s3, "obj-explain")
      assert decode(s3_a2)["run_completed"] == true
      backdate("learning_attempts", decode(s3_a1)["attempt_id"], "created_at", eight_days_ago)
      backdate("learning_attempts", decode(s3_a2)["attempt_id"], "created_at", eight_days_ago)
      backdate("workflow_runs", decode(s3_start)["run_id"], "inserted_at", eight_days_ago)

      # s4:新鲜零 attempt run
      %{learner: s4} = enroll_learner(ctx, "la-stale", "s4")
      assert {:reply, _, _} = start(ctx, s4)

      assert {:reply, _, _} = reply = analytics(ctx, tutor)
      {_raw, payload} = reply_parts(reply)

      assert payload["run_stats"]["total_runs"] == 4
      assert payload["run_stats"]["active_runs"] == 3
      assert payload["run_stats"]["completed_runs"] == 1
      assert payload["drop_off"] == %{"stale_run_count" => 2}
    end
  end

  describe "授权矩阵 + 审计" do
    test "tutor / owner 放行;plain member forbidden;outsider 被 member-only 门拒;落 ToolCallLog" do
      ctx = learning_ctx("la-auth")
      tutor = Fixtures.register_user("la-auth-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])
      member = Fixtures.register_user("la-auth-member")
      Fixtures.add_member(ctx.workspace, member, [:learner])
      outsider = Fixtures.register_user("la-auth-outsider")

      # tutor 放行
      assert {:reply, _, _} = analytics(ctx, tutor)
      assert [log] = tool_logs_for(tutor.id, "get_course_learning_analytics")
      assert log.result_status == :ok

      # owner(工作台创建者)放行
      assert {:reply, _, _} = analytics(ctx, ctx.admin)
      assert [log] = tool_logs_for(ctx.admin.id, "get_course_learning_analytics")
      assert log.result_status == :ok

      # plain member(仅 learner 标签)→ 工具层 forbidden
      assert {:error, %Anubis.MCP.Error{message: msg}, _} = analytics(ctx, member)
      assert msg =~ "forbidden"
      assert [log] = tool_logs_for(member.id, "get_course_learning_analytics")
      assert log.result_status == :forbidden

      # outsider → member-only 门拒(不经工具层)
      assert {:error, %Anubis.MCP.Error{message: msg}, _} = analytics(ctx, outsider)
      assert msg =~ "not a member"
      assert [log] = tool_logs_for(outsider.id, "get_course_learning_analytics")
      assert log.result_status == :forbidden
    end

    test "他租户 course_id 与不存在同一「not found」(租户收紧,不泄露存在性)" do
      ctx = learning_ctx("la-xtenant")
      tutor = Fixtures.register_user("la-xtenant-tutor")
      Fixtures.add_member(ctx.workspace, tutor, [:tutor])

      other_admin = Fixtures.platform_admin("la-xtenant-other")
      other_workspace = Fixtures.create_workspace(other_admin)
      other_course = EventFixtures.create_course(other_workspace, other_admin, %{title: "B 租户课程"})

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               GetCourseLearningAnalytics.execute(
                 %{"workspace_id" => ctx.workspace.id, "course_id" => other_course.id},
                 frame_for(tutor)
               )

      assert msg =~ "course not found"
    end
  end

  defp decode({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end
end
