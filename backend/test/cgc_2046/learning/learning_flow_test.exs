defmodule Cgc2046.Learning.LearningFlowTest do
  @moduledoc """
  学习 workflow 协议落地验收（E-7 #122）。

  覆盖任务书四条验收：

  1. `enrollment.completed` → 幂等实例化（重复投递只种一个 run）；
  2. 学员本人（非成员）写 facts，含 `reason` 落授权账本（D6-① variance）；
     StepRole 配置了非学员角色时学员豁免分支仍放行（设计 §4.1）；
  3. 非学员/非成员写被拒；学员写**他人** learning run 被拒；
  4. 末个 manual step 已写 → LearningProgressWorker 置 `succeeded`（D6-②）；
     停滞 > 7 天 → 提醒任务入队（D6-③，不自动 cancel）。

  测试直调 `SignalSubscriber.deliver/2`（同步，与生产 forwarder 同码，不依赖
  异步信号投递）；工具层直调 `SaveStepOutput.execute/2`（ToolsTest 同款
  frame 注入）。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Anubis.Server.Frame

  alias Cgc2046.Accounts.Role
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Mcp.Tools.SaveStepOutput
  alias Cgc2046.Workflows.SignalIdempotency
  alias Cgc2046.Workflows.SignalSubscriber
  alias Cgc2046.Learning.LearningProgressWorker
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Learning.LearningInstantiator
  alias Cgc2046.Workflows.Step
  alias Cgc2046.Workflows.StepRole
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias Cgc2046.Workflows.SignalPublishWorker

  require Ash.Query

  @final_step "final_reflection"

  # 测试纪律：enroll 必须早于 create_learning_definition——enrollment.completed
  # 信号在学习定义 published 之前发出，常驻订阅方（崩溃隔离后不再停掉）因
  # 定义缺失而 skip，实例化只由测试同步直调触发，无异步竞争。
  defp learning_node_def do
    %{
      "steps" => [
        %{"id" => "module_reading", "type" => "manual"},
        %{"id" => @final_step, "type" => "manual"}
      ]
    }
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
          node_def: learning_node_def()
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

  defp enroll(event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
    |> Ash.create(tenant: event.workspace_id, actor: learner)
  end

  defp instantiate(enrollment) do
    :ok =
      SignalSubscriber.deliver(LearningInstantiator, %{
        type: "enrollment.completed",
        data: %{
          "enrollment_id" => enrollment.id,
          "idempotency_key" => "enrollment.completed:" <> enrollment.id
        }
      })
  end

  # 常驻订阅方（崩溃隔离，测试不停掉）可能抢先 claim 并异步创建同一 run——
  # 幂等保证殊途同归，但创建时点不确定。断言统一走轮询等待（25ms × 80 = 2s 上限），
  # 消除「sync 直调 vs 异步转发进程」的竞争。
  defp await_run(definition_id, user_id, attempts \\ 80) do
    case learning_runs(definition_id, user_id) do
      [run] ->
        run

      [] when attempts > 0 ->
        Process.sleep(25)
        await_run(definition_id, user_id, attempts - 1)

      [] ->
        flunk("learning run not created for user #{user_id} (definition #{definition_id})")
    end
  end

  # D8（issue #505）：run 查询锚 = subject_user_id 列（user × revision 去重
  # 真源）；instance key 已降级为可读标签，不作断言锚。
  defp learning_runs(definition_id, user_id) do
    WorkflowRun
    |> Ash.Query.filter(definition_id == ^definition_id and subject_user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_run(run_id, workspace_id) do
    Ash.get!(WorkflowRun, run_id, tenant: workspace_id, authorize?: false)
  end

  defp save_output(user, workspace, run, step_key, output, reason \\ nil) do
    params = %{
      "workspace_id" => workspace.id,
      "run_id" => run.id,
      "step_key" => step_key,
      "output" => output
    }

    params = if reason, do: Map.put(params, "reason", reason), else: params

    SaveStepOutput.execute(params, Frame.new(current_user: user))
  end

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  # workspace create 时已 seed 六角色（owner/admin/member/tutor/volunteer/learner），按 name 取
  defp role_by_name(workspace, name) do
    {:ok, role} =
      Role
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one(tenant: workspace.id, authorize?: false)

    role
  end

  defp create_step_with_role(workspace, actor, defn, step_key, role_name) do
    {:ok, step} =
      Step
      |> Ash.Changeset.for_create(
        :create,
        %{definition_id: defn.id, step_key: step_key, title: step_key, type: :manual},
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    role = role_by_name(workspace, role_name)

    {:ok, _} =
      StepRole
      |> Ash.Changeset.for_create(
        :create,
        %{step_id: step.id, role_id: role.id},
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)
  end

  # 平台身份布置（speaker_flow_test 同款：register_user 只建账号不建平台身份；
  # 通知入队按 UserIdentity 精确投递）
  defp insert_identity(user_id, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp backdate_run(run, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    # S8 停滞口径 = last_activity_at（最新 attempt，零 attempt 回退 inserted_at）：
    # backdate 两者（零 attempt 路径走 inserted_at；updated_at 不再代理但一并
    # 回拨保持布景一致）
    Cgc2046.Repo.query!(
      "UPDATE workflow_runs SET updated_at = $1, inserted_at = $1 WHERE id = $2",
      [cutoff, Ecto.UUID.dump!(run.id)]
    )
  end

  describe "实例化（验收 1）" do
    test "enrollment.completed → 种 learning run（running，user × revision 锚定）" do
      admin = Fixtures.platform_admin("lf-inst")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{title: "学习活动"})
      learner = Fixtures.register_user("lf-inst-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)

      assert enrollment.status == :confirmed
      instantiate(enrollment)

      run = await_run(published.id, learner.id)

      assert run.status == :running
      assert run.definition_version == published.version
      assert run.facts == %{}

      assert run.input_snapshot["enrollment_id"] == enrollment.id
      assert run.input_snapshot["user_id"] == learner.id
      assert run.input_snapshot["event_id"] == event.id
      assert run.input_snapshot["title"] == "学习活动"
    end

    test "重复投递只种一个 run（claim + find_or_create 两层幂等）" do
      admin = Fixtures.platform_admin("lf-idem")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-idem-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)

      instantiate(enrollment)

      # claim_in_handle：校验链后才 claim，重复投递由 LI 归一化为 :ok（旧
      # instantiate_from_signal/2 语义）；claim 行只此一条，find_or_create 仍兜底
      assert :ok =
               SignalSubscriber.deliver(LearningInstantiator, %{
                 type: "enrollment.completed",
                 data: %{
                   "enrollment_id" => enrollment.id,
                   "idempotency_key" => "enrollment.completed:" <> enrollment.id
                 }
               })

      claim_key = "enrollment.completed:" <> enrollment.id <> ":learning_instantiator"

      assert [%{idempotency_key: ^claim_key}] =
               SignalIdempotency
               |> Ash.Query.filter(signal_type == "enrollment.completed")
               |> Ash.read!(authorize?: false)

      _run = await_run(published.id, learner.id)
    end

    test "pending（未 confirmed）报名不实例化（孤儿防护）" do
      admin = Fixtures.platform_admin("lf-orphan")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})

      learner = Fixtures.register_user("lf-orphan-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)

      assert enrollment.status == :pending
      instantiate(enrollment)

      assert learning_runs(published.id, learner.id) == []
    end

    test "无 published 学习定义 → warning skip 不种 run（供对账）" do
      admin = Fixtures.platform_admin("lf-nodef")
      workspace = Fixtures.create_workspace(admin)

      # #348 后新 workspace 恒 seed published 定义——异常态(无定义)布景直删
      Cgc2046.Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
        Ecto.UUID.dump!(workspace.id)
      ])

      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-nodef-learner")
      {:ok, enrollment} = enroll(event, learner)

      instantiate(enrollment)

      assert Ash.read!(WorkflowRun, authorize?: false) == []
    end
  end

  describe "1i 发布补种（course_revision.published）" do
    test "课程报名未发布不种 run；发布换绑触发信号；投递后补种存量报名" do
      admin = Fixtures.platform_admin("lf-reseed")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "入门课"})
      learner = Fixtures.register_user("lf-reseed-learner")

      {:ok, enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(
          :create_enrollment,
          %{course_id: course.id, user_id: learner.id}
        )
        |> Ash.create(tenant: workspace.id, actor: learner)

      published = create_learning_definition(workspace, admin)

      # 课程无 published revision → 不种空协议 run（1i：等发布补种）
      instantiate(enrollment)
      assert learning_runs(published.id, learner.id) == []

      {:ok, revision} =
        Cgc2046.Curriculum.CourseRevision
        |> Ash.Changeset.for_create(
          :create,
          %{
            course_id: course.id,
            number: 1,
            content: %{"goals" => [], "issues" => []},
            published_at: DateTime.utc_now()
          },
          tenant: workspace.id
        )
        |> Ash.create(tenant: workspace.id, authorize?: false)

      # 发布换绑（真实 action）→ 补种信号事务内入队
      course
      |> Ash.Changeset.for_update(:bind_current_revision, %{current_revision_id: revision.id},
        tenant: workspace.id
      )
      |> Ash.update!(tenant: workspace.id, authorize?: false)

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "course_revision.published",
          # BLOCKING 1 回归：生产幂等键必须是 revision 维度（换版独立补种；
          # emitter 缺省 course 维度键会让换版补种被 duplicate 吞掉）。
          "data" => %{"idempotency_key" => "course_revision.published:" <> revision.id}
        }
      )

      # 投递补种信号 → 存量 confirmed 报名补种锚定 run
      assert :ok =
               SignalSubscriber.deliver(LearningInstantiator, %{
                 type: "course_revision.published",
                 data: %{
                   "course_id" => course.id,
                   "course_revision_id" => revision.id,
                   "workspace_id" => workspace.id,
                   "idempotency_key" => "course_revision.published:" <> revision.id
                 }
               })

      run = await_run(published.id, learner.id)
      assert run.input_snapshot["course_revision_id"] == revision.id
      assert run.input_snapshot["enrollment_id"] == enrollment.id
      assert run.input_snapshot["course_id"] == course.id

      # 重复投递（幂等键同）→ 不重复补种
      assert :ok =
               SignalSubscriber.deliver(LearningInstantiator, %{
                 type: "course_revision.published",
                 data: %{
                   "course_id" => course.id,
                   "course_revision_id" => revision.id,
                   "workspace_id" => workspace.id,
                   "idempotency_key" => "course_revision.published:" <> revision.id
                 }
               })

      assert [%{id: only_id}] = learning_runs(published.id, learner.id)
      assert only_id == run.id
    end
  end

  describe "授权账本写路径（验收 2）" do
    test "学员本人（非成员）写 facts，reason 随 output 同次浅合并落账本" do
      admin = Fixtures.platform_admin("lf-write")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-write-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)
      instantiate(enrollment)
      run = await_run(published.id, learner.id)

      reply =
        save_output(learner, workspace, run, "module_reading", %{"notes" => "读完第三章"}, "跳过了视频")

      payload = decode_reply(reply)
      assert payload["run_id"] == run.id
      assert payload["step_key"] == "module_reading"
      assert payload["status"] == "running"

      reloaded = fetch_run(run.id, workspace.id)

      assert reloaded.facts["module_reading"] == %{
               "notes" => "读完第三章",
               "reason" => "跳过了视频"
             }

      # 无 reason 的写入不生成 reason 键（D6-①：无 reason 不写该键）
      reply2 = save_output(learner, workspace, run, @final_step, %{"essay" => "总结"})
      assert decode_reply(reply2)["step_key"] == @final_step

      reloaded2 = fetch_run(run.id, workspace.id)
      assert reloaded2.facts[@final_step] == %{"essay" => "总结"}
    end

    test "StepRole 配置了非学员角色时，学员豁免分支仍放行（设计 §4.1 核心接线）" do
      admin = Fixtures.platform_admin("lf-exempt")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-exempt-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)

      # module_reading 配置 tutor 角色——学员无成员角色，StepRole 判定必失败，
      # 放行即证明学员豁免分支生效（而非「未配置 = 不限制」路径）。
      create_step_with_role(workspace, admin, published, "module_reading", :tutor)
      instantiate(enrollment)
      run = await_run(published.id, learner.id)

      reply = save_output(learner, workspace, run, "module_reading", %{"notes" => "ok"})
      assert decode_reply(reply)["step_key"] == "module_reading"

      assert fetch_run(run.id, workspace.id).facts["module_reading"] == %{"notes" => "ok"}
    end

    test "非学员非成员写被拒；学员写他人 learning run 被拒" do
      admin = Fixtures.platform_admin("lf-reject")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-reject-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)
      instantiate(enrollment)
      run = await_run(published.id, learner.id)

      # 非成员非学员（outsider）
      outsider = Fixtures.register_user("lf-reject-outsider")

      assert {:error, %Anubis.MCP.Error{message: msg}, _frame} =
               save_output(outsider, workspace, run, "module_reading", %{"notes" => "x"})

      assert msg =~ "unauthorized" or msg =~ "forbidden"

      # 另一报名的学员（是学员，但不是这个 run 的报名本人）
      other_learner = Fixtures.register_user("lf-reject-other")
      {:ok, _other_enrollment} = enroll(event, other_learner)

      assert {:error, %Anubis.MCP.Error{message: msg2}, _frame} =
               save_output(other_learner, workspace, run, "module_reading", %{"notes" => "x"})

      assert msg2 =~ "unauthorized" or msg2 =~ "forbidden"

      assert fetch_run(run.id, workspace.id).facts == %{}
    end

    test "学员豁免不覆盖治理保留 key：学员写 prep_policy_override 被拒（P1）" do
      admin = Fixtures.platform_admin("lf-reserved")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      learner = Fixtures.register_user("lf-reserved-learner")
      {:ok, enrollment} = enroll(event, learner)
      published = create_learning_definition(workspace, admin)
      instantiate(enrollment)
      run = await_run(published.id, learner.id)

      # 学员本人 + 学习 run（豁免双前提都满足）——保留 key 拒绝先于授权判定
      assert {:error, %Anubis.MCP.Error{message: msg}, _frame} =
               save_output(learner, workspace, run, "prep_policy_override", %{
                 "review_required" => false
               })

      assert msg =~ "reserved fact key"
      assert fetch_run(run.id, workspace.id).facts == %{}
    end
  end

  describe "完成判定（验收 3；U4 升级：全 issue Done）" do
    test "事件型 run（无 course content）不判完成；末步 facts 不再触发" do
      admin = Fixtures.platform_admin("lf-complete")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      finisher = Fixtures.register_user("lf-complete-finisher")
      {:ok, enrollment_done} = enroll(event, finisher)
      published = create_learning_definition(workspace, admin)

      instantiate(enrollment_done)

      run_done =
        await_run(published.id, finisher.id)

      # 旧口径:写末步 facts 即完成;U4 起事件型 run 无课程内容 → 不判完成
      save_output(finisher, workspace, run_done, @final_step, %{"essay" => "毕业总结"})

      assert :ok = perform_job(LearningProgressWorker, %{})
      assert fetch_run(run_done.id, workspace.id).status == :running
    end
  end

  # 终态保护（save_step_output 不改状态，单一职责）随 U4 迁至
  # course_tools_test 场景 5(run succeeded 后 save_learning_records 仍可写)。

  describe "停滞升级（验收 4）" do
    test "running 且 7 天无写入 → 提醒任务入队；新 run 不提醒；不自动 cancel" do
      admin = Fixtures.platform_admin("lf-stale")
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{})
      stale_learner = Fixtures.register_user("lf-stale-learner")
      {:ok, stale_enrollment} = enroll(event, stale_learner)
      fresh_learner = Fixtures.register_user("lf-fresh-learner")
      {:ok, fresh_enrollment} = enroll(event, fresh_learner)
      published = create_learning_definition(workspace, admin)

      instantiate(stale_enrollment)

      stale_run =
        await_run(published.id, stale_learner.id)

      instantiate(fresh_enrollment)

      fresh_run =
        await_run(published.id, fresh_learner.id)

      insert_identity(stale_learner.id, "wechat-uid-stale")
      insert_identity(fresh_learner.id, "wechat-uid-fresh")

      # 8 天无 facts 新增（updated_at 代理）
      backdate_run(stale_run, 8)

      assert :ok = perform_job(LearningProgressWorker, %{})

      assert_enqueued(
        worker: NotificationWorker,
        args: %{
          "user_id" => stale_learner.id,
          "platform" => "wechat",
          "template_key" => "learning_stagnation",
          "data" => %{"run_id" => stale_run.id, "enrollment_id" => stale_enrollment.id}
        }
      )

      refute_enqueued(
        worker: NotificationWorker,
        args: %{"template_key" => "learning_stagnation", "data" => %{"run_id" => fresh_run.id}}
      )

      # 不自动 cancel：停滞 run 仍 running
      assert fetch_run(stale_run.id, workspace.id).status == :running
    end
  end
end
