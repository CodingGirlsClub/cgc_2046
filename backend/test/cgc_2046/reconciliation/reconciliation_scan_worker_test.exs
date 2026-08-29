defmodule Cgc2046.Reconciliation.ReconciliationScanWorkerTest do
  @moduledoc """
  E-10 #125 对账扫描 worker 测试（D9）。

  每规则至少一例正反：注入孤儿 → `perform_job` → Finding 命中对应规则；
  消解 → 再扫 → 空（刷新语义 D2：命中 upsert 保 first_seen_at、未命中删除）。
  规3/6 的 oban_jobs discarded 状态用 SQL 直写（approval_reminder_worker_test 先例）。
  """

  use Cgc2046Web.ConnCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Reconciliation.ReconciliationScanWorker
  alias Cgc2046.Workflows.SignalPublishWorker
  alias Cgc2046.Learning.Runs
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  # ── 规6 白名单完整性(ADR-0010 W1:防字符串漂移→规则失明)──────────────────

  test "规6 死信白名单的每个模块名字符串必须对应真实存在的模块" do
    for name <- ReconciliationScanWorker.dead_letter_workers() do
      assert Code.ensure_loaded?(String.to_atom("Elixir." <> name)),
             "死信白名单模块不存在(改名后字符串未随迁): #{name}"
    end
  end

  # ── 查询助手 ------------------------------------------------------------------

  defp findings(rule) do
    Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read!(authorize?: false)
  end

  # ── 布置助手 ------------------------------------------------------------------

  defp create_published_definition(workspace, actor, type) do
    assert {:ok, defn} =
             WorkflowDefinition
             |> Ash.Changeset.for_create(:create, %{
               name: "defn-#{type}",
               type: type,
               input_schema: %{"text" => "string"},
               node_def: %{"steps" => []}
             })
             |> Ash.create(tenant: workspace.id, actor: actor)

    assert {:ok, published} =
             defn
             |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
             |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  # open 事件自动确认报名（enrollment_policy: :open → status=:confirmed）
  defp create_confirmed_enrollment(event, workspace, learner) do
    assert {:ok, enrollment} =
             Enrollment
             |> Ash.Changeset.for_create(:create_enrollment, %{
               event_id: event.id,
               user_id: learner.id
             })
             |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :confirmed
    enrollment
  end

  defp create_learning_run(workspace, actor, definition, enrollment_id) do
    assert {:ok, run} =
             WorkflowRun
             |> Ash.Changeset.for_create(
               :create,
               %{
                 definition_id: definition.id,
                 definition_version: definition.version,
                 input_snapshot: %{
                   "key" => "enrollment_#{enrollment_id}",
                   "enrollment_id" => enrollment_id
                 }
               },
               tenant: workspace.id,
               actor: actor
             )
             |> Ash.create(tenant: workspace.id, actor: actor)

    run
  end

  defp create_curriculum_run(workspace, actor, definition, key) do
    assert {:ok, run} =
             WorkflowRun
             |> Ash.Changeset.for_create(
               :create,
               %{
                 definition_id: definition.id,
                 definition_version: definition.version,
                 input_snapshot: %{"key" => key}
               },
               tenant: workspace.id,
               actor: actor
             )
             |> Ash.create(tenant: workspace.id, actor: actor)

    run
  end

  # Event/Course 状态置位（布置而非被测对象，EventsFixtures.force_open 同款先例）
  defp force_status(table, id, status) do
    {:ok, _} =
      Repo.query("UPDATE #{table} SET status = '#{status}' WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])
  end

  defp force_run_status(run, status) do
    {:ok, _} =
      Repo.query("UPDATE workflow_runs SET status = '#{status}' WHERE id = $1", [
        Ecto.UUID.dump!(run.id)
      ])
  end

  # 建 active 赞助（event 级：create pending → approve → active，事务内入队
  # sponsorship.approved + sponsorship.active 两 job）
  defp create_active_sponsorship(workspace, event, sponsor) do
    assert {:ok, sponsorship} =
             Sponsorship
             |> Ash.Changeset.for_create(:create_sponsorship, %{
               level: :event,
               event_id: event.id,
               sponsor_user_id: sponsor.id,
               company_name: "Acme",
               contact_email: "sponsor@example.com"
             })
             |> Ash.create(tenant: workspace.id, actor: sponsor, authorize?: false)

    assert {:ok, active} =
             sponsorship
             |> Ash.Changeset.for_update(:approve_sponsorship, %{})
             |> Ash.update(tenant: workspace.id, actor: sponsor, authorize?: false)

    assert active.status == :active
    active
  end

  defp discard_sponsorship_active_job(sponsorship) do
    {:ok, %{rows: [[job_id]]}} =
      Repo.query(
        "SELECT id FROM oban_jobs WHERE worker = 'Cgc2046.Workflows.SignalPublishWorker' " <>
          "AND args->>'signal_type' = 'sponsorship.active' " <>
          "AND args->'data'->>'idempotency_key' = $1",
        ["sponsorship.active:" <> sponsorship.id]
      )

    {:ok, _} = Repo.query("UPDATE oban_jobs SET state = 'discarded' WHERE id = $1", [job_id])
    job_id
  end

  # ── 规1：confirmed enrollment 无 learning run --------------------------------

  describe "规1 confirmed enrollment 无 learning run" do
    test "注入孤儿 → 命中；补 run 消解 → 空" do
      admin = Fixtures.platform_admin("rc1-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc1-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:confirmed_enrollment_without_run)
      assert finding.entity_type == :enrollment
      assert finding.entity_id == enrollment.id
      assert finding.workspace_id == workspace.id
      assert finding.detail["event_id"] == event.id

      # 消解：为该 enrollment 补 learning run
      create_learning_run(workspace, admin, learning_defn, enrollment.id)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:confirmed_enrollment_without_run)
    end

    test "已有 learning run（任意终态，BYO 不看 run 终态）→ 不命中" do
      admin = Fixtures.platform_admin("rc1-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc1-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      run = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      # 终态 run（如已 succeeded）也算「存在 learning run」——BYO 无平台终态
      force_run_status(run, "succeeded")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:confirmed_enrollment_without_run)
    end
  end

  # ── 规2：pending 无 approval_deadline ----------------------------------------

  describe "规2 pending 无 approval_deadline" do
    test "四资源孤儿 UNION 各命中一例" do
      admin = Fixtures.platform_admin("rc2-admin")
      workspace = Fixtures.create_workspace(admin)

      # Enrollment：confirmed 报名回拨 pending + 清空 deadline
      learner = Fixtures.register_user("rc2-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)

      Repo.query!(
        "UPDATE enrollments SET status = 'pending', approval_deadline = NULL WHERE id = $1",
        [Ecto.UUID.dump!(enrollment.id)]
      )

      # Sponsorship：pending 赞助清空 deadline
      sponsor = Fixtures.register_user("rc2-sponsor")
      sponsorship = create_pending_sponsorship(workspace, event, sponsor)

      Repo.query!(
        "UPDATE sponsorships SET approval_deadline = NULL WHERE id = $1",
        [Ecto.UUID.dump!(sponsorship.id)]
      )

      # JoinRequest：pending 申请清空 deadline
      applicant = Fixtures.register_user("rc2-applicant")
      join_request = create_join_request(workspace, applicant)

      Repo.query!(
        "UPDATE join_requests SET approval_deadline = NULL WHERE id = $1",
        [Ecto.UUID.dump!(join_request.id)]
      )

      # WorkspaceApplication：全局资源（无 workspace_id 列）
      app_user = Fixtures.register_user("rc2-app")
      application = create_workspace_application(app_user)

      Repo.query!(
        "UPDATE workspace_applications SET approval_deadline = NULL WHERE id = $1",
        [Ecto.UUID.dump!(application.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert Enum.sort(Enum.map(findings(:pending_without_deadline), & &1.entity_type)) ==
               [:enrollment, :join_request, :sponsorship, :workspace_application]

      assert Enum.any?(findings(:pending_without_deadline), &is_nil(&1.workspace_id))
    end

    test "pending 带 approval_deadline → 不命中" do
      admin = Fixtures.platform_admin("rc2-admin")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("rc2-applicant")
      # 创建路径必写 deadline，默认 7 天 → 非孤儿
      create_join_request(workspace, applicant)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:pending_without_deadline)
    end
  end

  # ── 规3：active sponsorship 的 sponsorship.active 发布 job 死信 ---------------

  describe "规3 active sponsorship 的 sponsorship.active 发布 job 死信" do
    test "active 赞助 + 发布 job discarded → 命中" do
      admin = Fixtures.platform_admin("rc3-admin")
      workspace = Fixtures.create_workspace(admin)
      sponsor = Fixtures.register_user("rc3-sponsor")
      event = EventFixtures.create_event(workspace, admin)
      sponsorship = create_active_sponsorship(workspace, event, sponsor)
      discard_sponsorship_active_job(sponsorship)

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:active_sponsorship_signal_dead)
      assert finding.entity_type == :sponsorship
      assert finding.entity_id == sponsorship.id
      assert finding.workspace_id == workspace.id
    end

    test "active 赞助 + 发布 job 非 discarded（在途）→ 不命中" do
      admin = Fixtures.platform_admin("rc3-admin")
      workspace = Fixtures.create_workspace(admin)
      sponsor = Fixtures.register_user("rc3-sponsor")
      event = EventFixtures.create_event(workspace, admin)
      # approve 后 sponsorship.active job 保持 available（testing: :manual 不执行）
      create_active_sponsorship(workspace, event, sponsor)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:active_sponsorship_signal_dead)
    end

    test "discarded job 但赞助非 active（pending）→ 不命中" do
      admin = Fixtures.platform_admin("rc3-admin")
      workspace = Fixtures.create_workspace(admin)
      sponsor = Fixtures.register_user("rc3-sponsor")
      event = EventFixtures.create_event(workspace, admin)
      pending = create_pending_sponsorship(workspace, event, sponsor)

      # 直接造一条该赞助的 sponsorship.active 死信 job（pending 走不到审批入队）
      {:ok, job} =
        Oban.insert(
          SignalPublishWorker.new(%{
            "signal_type" => "sponsorship.active",
            "data" => %{
              "idempotency_key" => "sponsorship.active:#{pending.id}",
              "workspace_id" => workspace.id
            }
          })
        )

      Repo.query!("UPDATE oban_jobs SET state = 'discarded' WHERE id = $1", [job.id])

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:active_sponsorship_signal_dead)
    end
  end

  # ── 规4：open 且 curriculum_enabled 但工作台无 published 教研定义 ---------------

  describe "规4 open 实体无 published 教研定义" do
    test "open event/course 无教研定义 → 各命中一例" do
      admin = Fixtures.platform_admin("rc4-admin")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{title: "RC4 Event"})
      EventFixtures.create_course(workspace, admin, %{title: "RC4 Course"})

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      findings = findings(:open_entity_without_research_definition)
      assert Enum.sort(Enum.map(findings, & &1.entity_type)) == [:course, :event]
      assert Enum.all?(findings, &(&1.workspace_id == workspace.id))
      assert Enum.any?(findings, &(&1.detail["title"] == "RC4 Event"))
    end

    test "工作台有 published 教研定义 → 不命中" do
      admin = Fixtures.platform_admin("rc4-admin")
      workspace = Fixtures.create_workspace(admin)
      create_published_definition(workspace, admin, :curriculum)
      EventFixtures.create_event(workspace, admin)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end

    test "curriculum_enabled = false 合法不命中" do
      admin = Fixtures.platform_admin("rc4-admin")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{curriculum_enabled: false})

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end
  end

  # ── 规5：closed/cancelled 实体仍有非终态 curriculum run ------------------------

  describe "规5 closed/cancelled 实体仍有非终态 curriculum run" do
    test "closed event + 非终态 run → 命中；消解（run 转终态）→ 空" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      curriculum_defn = create_published_definition(workspace, admin, :curriculum)
      event = EventFixtures.create_event(workspace, admin)
      force_status("events", event.id, "closed")
      run = create_curriculum_run(workspace, admin, curriculum_defn, "event_#{event.id}")

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:nonterminal_research_run_for_closed_entity)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.detail["run_id"] == run.id

      # 消解：reaper 语义 = run 转终态（cancelled）
      force_run_status(run, "cancelled")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:nonterminal_research_run_for_closed_entity)
    end

    test "cancelled course + 非终态 run → 不命中（S6 event-only，存量行自然 aging）" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      curriculum_defn = create_published_definition(workspace, admin, :curriculum)
      course = EventFixtures.create_course(workspace, admin)
      force_status("courses", course.id, "cancelled")
      create_curriculum_run(workspace, admin, curriculum_defn, "course_#{course.id}")

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [] = findings(:nonterminal_research_run_for_closed_entity)
    end

    test "closed 实体但 run 已终态 → 不命中" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      curriculum_defn = create_published_definition(workspace, admin, :curriculum)
      event = EventFixtures.create_event(workspace, admin)
      force_status("events", event.id, "closed")
      run = create_curriculum_run(workspace, admin, curriculum_defn, "event_#{event.id}")
      force_run_status(run, "succeeded")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:nonterminal_research_run_for_closed_entity)
    end

    test "open 实体 + 非终态 run → 不命中（仅 closed/cancelled 判孤儿）" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      curriculum_defn = create_published_definition(workspace, admin, :curriculum)
      event = EventFixtures.create_event(workspace, admin)
      create_curriculum_run(workspace, admin, curriculum_defn, "event_#{event.id}")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:nonterminal_research_run_for_closed_entity)
    end
  end

  # ── 规6：信号族死信（7 天窗口内）---------------------------------------------

  describe "规6 信号族死信" do
    test "discarded NotificationWorker job（7 天内）→ 命中" do
      {:ok, job} = Oban.insert(NotificationWorker.new(%{"template_key" => "rc6-a"}))
      Repo.query!("UPDATE oban_jobs SET state = 'discarded' WHERE id = $1", [job.id])

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:dead_letter_job)
      assert finding.entity_type == :oban_job
      assert finding.entity_id == to_string(job.id)
      assert finding.detail["worker"] == "Cgc2046.Notifications.NotificationWorker"
      assert is_nil(finding.workspace_id)
    end

    test "discarded 超出 7 天窗口 → 不命中（Pruner 窗口外不判定）" do
      {:ok, job} = Oban.insert(NotificationWorker.new(%{"template_key" => "rc6-old"}))
      Repo.query!("UPDATE oban_jobs SET state = 'discarded' WHERE id = $1", [job.id])

      Repo.query!("UPDATE oban_jobs SET inserted_at = NOW() - INTERVAL '8 days' WHERE id = $1", [
        job.id
      ])

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:dead_letter_job)
    end

    test "available（未死信）→ 不命中" do
      Oban.insert(NotificationWorker.new(%{"template_key" => "rc6-live"}))

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:dead_letter_job)
    end
  end

  # ── 规7：learning run 停滞（> 7d 无 facts 更新，与 LPW 提醒同源判定）---------

  describe "规7 learning run 停滞" do
    test "running learning run 停滞 > 7 天 → 命中；消解（run 转终态）→ 空" do
      admin = Fixtures.platform_admin("rc7-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc7-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      run = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      force_run_status(run, "running")
      backdate_run(run, Runs.stagnant_cutoff() |> DateTime.add(-3600, :second))

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:learning_run_stalled)
      assert finding.entity_type == :workflow_run
      assert finding.entity_id == run.id
      assert finding.workspace_id == workspace.id
      assert finding.detail["enrollment_id"] == enrollment.id

      # 消解：停滞 run 转终态（学员侧推进 / 人工干预）→ 下一拍删除
      force_run_status(run, "succeeded")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:learning_run_stalled)
    end

    test "活跃 run（新近活动）→ 不命中" do
      admin = Fixtures.platform_admin("rc7-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc7-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      run = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      force_run_status(run, "running")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:learning_run_stalled)
    end

    test "7 天边界两侧：未满 7 天不命中，超过 7 天命中（严格 :lt 口径）" do
      admin = Fixtures.platform_admin("rc7-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      event = EventFixtures.create_event(workspace, admin)

      # 测试与扫描各算一次 cutoff（亚秒偏差）——用 ±60s 裕度做确定性两侧断言
      cutoff = Runs.stagnant_cutoff()

      # cutoff + 60s：7 天差 1 分钟，未满 7 天 → 不命中
      learner_a = Fixtures.register_user("rc7-learner-a")
      enrollment_a = create_confirmed_enrollment(event, workspace, learner_a)
      run_a = create_learning_run(workspace, admin, learning_defn, enrollment_a.id)
      force_run_status(run_a, "running")
      backdate_run(run_a, DateTime.add(cutoff, 60, :second))

      # cutoff - 60s：7 天零 1 分钟 → 命中
      learner_b = Fixtures.register_user("rc7-learner-b")
      enrollment_b = create_confirmed_enrollment(event, workspace, learner_b)
      run_b = create_learning_run(workspace, admin, learning_defn, enrollment_b.id)
      force_run_status(run_b, "running")
      backdate_run(run_b, DateTime.add(cutoff, -60, :second))

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:learning_run_stalled)
      assert finding.entity_id == run_b.id
    end

    test "非 running（pending/succeeded）→ 不命中" do
      admin = Fixtures.platform_admin("rc7-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc7-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      run = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      # 默认 pending（未 start）；再补一个 succeeded
      backdate_run(run, Runs.stagnant_cutoff() |> DateTime.add(-3600, :second))
      done = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      force_run_status(done, "succeeded")
      backdate_run(done, Runs.stagnant_cutoff() |> DateTime.add(-3600, :second))

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:learning_run_stalled)
    end

    test "重复扫描幂等：同 run 未消解 finding 不重复建，保 first_seen_at" do
      admin = Fixtures.platform_admin("rc7-admin")
      workspace = Fixtures.create_workspace(admin)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc7-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      run = create_learning_run(workspace, admin, learning_defn, enrollment.id)
      force_run_status(run, "running")
      backdate_run(run, Runs.stagnant_cutoff() |> DateTime.add(-3600, :second))

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [finding] = findings(:learning_run_stalled)
      first_seen = finding.first_seen_at

      # 回拨 last_seen_at → 第二拍 upsert 只推 last_seen_at（claim 语义不重复建）
      Repo.query!(
        "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
        [Ecto.UUID.dump!(finding.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [again] = findings(:learning_run_stalled)
      assert again.first_seen_at == first_seen
      assert DateTime.compare(again.last_seen_at, first_seen) == :gt
    end
  end

  # ── 规8-11：名额账本 / 展示投影（ADR-0009 PR⑤ U7；R17）------------------------

  describe "规8 open offering 无账本行" do
    test "open event 无账本行 → 命中；建行消解 → 空" do
      admin = Fixtures.platform_admin("rc8-admin")
      workspace = Fixtures.create_workspace(admin)
      # fixture force_open 不走 launched 信号、无报名懒建 → 账本行缺失
      event = EventFixtures.create_event(workspace, admin)

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:open_offering_without_ledger)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.workspace_id == workspace.id
      assert finding.detail["title"] == event.title

      # 消解：回查建行（launched 订阅同路径）
      assert :ok = Cgc2046.Admission.CapacityLedger.sync_from_offering(event)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_offering_without_ledger)
    end

    test "open course 无账本行 → 命中；报名懒建建行 → 不命中" do
      admin = Fixtures.platform_admin("rc8c-admin")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [finding] = findings(:open_offering_without_ledger)
      assert finding.entity_type == :course
      assert finding.entity_id == course.id

      # 消解：报名触发懒建（KTD5）
      learner = Fixtures.register_user("rc8c-learner")
      # create_confirmed_enrollment 是 event-only 助手，course 报名直接建
      assert {:ok, enrollment} =
               Enrollment
               |> Ash.Changeset.for_create(:create_enrollment, %{
                 course_id: course.id,
                 user_id: learner.id
               })
               |> Ash.create(tenant: workspace.id, actor: learner)

      assert enrollment.status == :confirmed

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_offering_without_ledger)
    end
  end

  describe "规9 账本 occupancy ≠ 占位报名计数" do
    test "占位报名后口径一致不命中；账本计数被抬 → 命中；恢复 → 空" do
      admin = Fixtures.platform_admin("rc9-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc9-learner")
      event = EventFixtures.create_event(workspace, admin)
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:ledger_occupancy_mismatch)

      # 注入漂移：账本 occupancy 抬到 3（报名计数仍 1）
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET occupancy = 3 WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_occupancy_mismatch)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.detail["occupancy"] == 3
      assert finding.detail["enrollment_count"] == 1

      # 消解：计数恢复一致
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET occupancy = 1 WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:ledger_occupancy_mismatch)
    end

    test "payment_pending 报名占席计入计数：账本 occupancy=1 与口径一致不命中" do
      admin = Fixtures.platform_admin("rc9p-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc9p-learner")
      tier_id = Ecto.UUID.generate()

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [%{"id" => tier_id, "name" => "标准", "amount_cents" => 19_900}]
        })

      assert {:ok, enrollment} =
               Enrollment
               |> Ash.Changeset.for_create(:create_enrollment, %{
                 event_id: event.id,
                 user_id: learner.id,
                 tier_id: tier_id
               })
               |> Ash.create(tenant: workspace.id, actor: learner)

      # 收费占位：payment_pending 已占席（账本 occupancy=1），规9口径含 payment_pending
      assert enrollment.status == :payment_pending
      assert EventFixtures.ledger_occupancy(event) == 1

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:ledger_occupancy_mismatch)
    end

    test "报名 cancelled 但账本 occupancy=1 → 命中且 detail 计数为 0" do
      admin = Fixtures.platform_admin("rc9c-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc9c-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 裸 SQL 置 cancelled（绕过领域 cancel 的名额释放，规9 同款注入纪律）：
      # 账本 occupancy 滞留 1，占位报名计数已为 0
      Repo.query!(
        "UPDATE enrollments SET status = 'cancelled' WHERE id = $1",
        [Ecto.UUID.dump!(enrollment.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_occupancy_mismatch)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.detail["occupancy"] == 1
      assert finding.detail["enrollment_count"] == 0
    end
  end

  describe "规10 展示投影漂移超一拍" do
    test "在途窗口不命中；账本变更超一拍且投影滞后 → 命中；投递同步消解 → 空" do
      admin = Fixtures.platform_admin("rc10-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc10-learner")
      event = EventFixtures.create_event(workspace, admin)
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 投影列（0）滞后账本（1）但账本刚变更——在一拍宽限内不告警
      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:capacity_projection_drift)

      # 回拨账本 updated_at 超一拍 → 漂移命中
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET updated_at = NOW() - INTERVAL '11 minutes' WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:capacity_projection_drift)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.detail["occupancy"] == 1
      assert finding.detail["confirmed_count"] == 0

      # 消解：投递 capacity.synced 真实 outbox 载荷，投影收敛
      payload =
        [worker: SignalPublishWorker]
        |> all_enqueued()
        |> Enum.find(
          &(&1.args["signal_type"] == "capacity.synced" &&
              get_in(&1.args, ["data", "event_id"]) == event.id)
        )
        |> Map.fetch!(:args)
        |> Map.fetch!("data")

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(
                 Cgc2046.Events.CapacityProjectionSubscriber,
                 %{type: "capacity.synced", data: payload}
               )

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:capacity_projection_drift)
    end
  end

  describe "规11 occupancy > capacity" do
    test "超员注入 → 命中；自然释放收敛 → 空" do
      admin = Fixtures.platform_admin("rc11-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc11-learner")
      event = EventFixtures.create_event(workspace, admin, %{capacity: 1})
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:occupancy_exceeds_capacity)

      # 注入 AE4 形态：capacity 1 < occupancy 2（调小后的合法超员窗口）
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET occupancy = 2 WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:occupancy_exceeds_capacity)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.detail["occupancy"] == 2
      assert finding.detail["capacity"] == 1

      # 消解：释放收敛回 capacity 内
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET occupancy = 1 WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:occupancy_exceeds_capacity)
    end
  end

  # ── 规12：账本缓存漂移（ADR-0009 Fable 5 HIGH-1；无宽限,缓存≠真值即报,缝隙修复见 worker 注释）

  describe "规12 账本缓存漂移（ledger_cache_drift）" do
    test "status 漂移（缓存滞留 open，真值已 closed = ended 信号丢投）→ 命中且 detail 双值" do
      admin = Fixtures.platform_admin("rc12-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12-learner")
      event = EventFixtures.create_event(workspace, admin)
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 注入漂移：真值转 closed（缓存仍 open = ended 信号丢投滞留）
      force_status("events", event.id, "closed")

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_cache_drift)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.workspace_id == workspace.id

      assert finding.detail["drifts"]["status"] == %{
               "ledger" => "open",
               "truth" => "closed"
             }
    end

    test "capacity 漂移（course 侧，capacity_changed 信号丢投）→ 命中" do
      admin = Fixtures.platform_admin("rc12c-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12c-learner")
      course = EventFixtures.create_course(workspace, admin, %{capacity: 10})

      assert {:ok, enrollment} =
               Enrollment
               |> Ash.Changeset.for_create(:create_enrollment, %{
                 course_id: course.id,
                 user_id: learner.id
               })
               |> Ash.create(tenant: workspace.id, actor: learner)

      assert enrollment.status == :confirmed

      # 注入漂移：真值调小到 5，缓存仍 10
      Repo.query!("UPDATE courses SET capacity = 5 WHERE id = $1", [
        Ecto.UUID.dump!(course.id)
      ])

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_cache_drift)
      assert finding.entity_type == :course
      assert finding.entity_id == course.id
      assert finding.detail["drifts"]["capacity"] == %{"ledger" => 10, "truth" => 5}
    end

    test "registration_deadline 漂移（缓存 NULL ≠ 真值）→ 命中" do
      admin = Fixtures.platform_admin("rc12d-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12d-learner")

      event =
        EventFixtures.create_event(workspace, admin, %{
          registration_deadline: DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
        })

      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 注入漂移：缓存 deadline 滞留 NULL，真值三天后截止
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET registration_deadline = NULL WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_cache_drift)
      assert finding.entity_type == :event
      assert finding.entity_id == event.id

      drift = finding.detail["drifts"]["registration_deadline"]
      assert is_nil(drift["ledger"])
      assert is_binary(drift["truth"])
    end

    test "缓存与真值一致 → 不命中" do
      admin = Fixtures.platform_admin("rc12ok-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12ok-learner")
      event = EventFixtures.create_event(workspace, admin)
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 缓存=真值（懒建同步值）——不命中
      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:ledger_cache_drift)
    end

    test "回归（锚点缝隙）：漂移存在时 release 刷新 updated_at 不再掩蔽告警" do
      admin = Fixtures.platform_admin("rc12g-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12g-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)

      # 注入漂移：真值转 closed（缓存仍 open = ended 信号丢投）
      force_status("events", event.id, "closed")

      # 缝隙触发器：release（取消报名）SET updated_at = NOW() 但不收敛 status
      # 缓存列——旧版宽限锚（l.updated_at < NOW()-600s）下本拍永不告警；
      # 无宽限后仍须命中（旧代码红、新代码绿）
      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:ledger_cache_drift)
      assert finding.entity_id == event.id

      assert finding.detail["drifts"]["status"] == %{
               "ledger" => "open",
               "truth" => "closed"
             }
    end

    test "重复扫描幂等：保 first_seen_at、推 last_seen_at；缓存收敛后消解" do
      admin = Fixtures.platform_admin("rc12i-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc12i-learner")
      event = EventFixtures.create_event(workspace, admin)
      _enrollment = create_confirmed_enrollment(event, workspace, learner)

      force_status("events", event.id, "closed")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [finding] = findings(:ledger_cache_drift)
      first_seen = finding.first_seen_at

      # 回拨 last_seen_at → 第二拍 upsert 只推 last_seen_at（claim 语义不重复建）
      Repo.query!(
        "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
        [Ecto.UUID.dump!(finding.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [again] = findings(:ledger_cache_drift)
      assert again.first_seen_at == first_seen
      assert DateTime.compare(again.last_seen_at, first_seen) == :gt

      # 消解：缓存覆盖写收敛（ended 订阅方回查同路径效果）→ 下一拍删除
      Repo.query!(
        "UPDATE admission_capacity_ledgers SET status = 'closed' WHERE offering_kind = 'event' AND offering_id = $1",
        [Ecto.UUID.dump!(event.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:ledger_cache_drift)
    end
  end

  # ── 刷新语义（D2）与空报告 ----------------------------------------------------

  describe "刷新语义" do
    test "无孤儿 → 空报告（全表无 Finding）" do
      admin = Fixtures.platform_admin("rc-empty-admin")
      workspace = Fixtures.create_workspace(admin)

      # 教研定义 + 学习定义都具备：open 实体、confirmed 报名、learning run 齐备
      create_published_definition(workspace, admin, :curriculum)
      learning_defn = create_published_definition(workspace, admin, :learning)
      learner = Fixtures.register_user("rc-empty-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)
      create_learning_run(workspace, admin, learning_defn, enrollment.id)

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [] = Finding |> Ash.read!(authorize?: false)
    end

    test "命中 upsert 保 first_seen_at、刷新 last_seen_at；消解后删除" do
      admin = Fixtures.platform_admin("rc-refresh-admin")
      workspace = Fixtures.create_workspace(admin)
      learner = Fixtures.register_user("rc-refresh-learner")
      event = EventFixtures.create_event(workspace, admin)
      enrollment = create_confirmed_enrollment(event, workspace, learner)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [finding] = findings(:confirmed_enrollment_without_run)
      first_seen = finding.first_seen_at

      # 回拨 last_seen_at → 第二拍 refresh 只推 last_seen_at
      Repo.query!(
        "UPDATE reconciliation_findings SET last_seen_at = NOW() - INTERVAL '1 day' WHERE id = $1",
        [Ecto.UUID.dump!(finding.id)]
      )

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [again] = findings(:confirmed_enrollment_without_run)
      assert again.first_seen_at == first_seen
      assert DateTime.compare(again.last_seen_at, first_seen) == :gt

      # 消解：取消报名（不再 confirmed）→ 下一拍删除 → 空
      Repo.query!("UPDATE enrollments SET status = 'cancelled' WHERE id = $1", [
        Ecto.UUID.dump!(enrollment.id)
      ])

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:confirmed_enrollment_without_run)
    end
  end

  # ── 私有布置 ------------------------------------------------------------------

  defp create_pending_sponsorship(workspace, event, sponsor) do
    assert {:ok, sponsorship} =
             Sponsorship
             |> Ash.Changeset.for_create(:create_sponsorship, %{
               level: :event,
               event_id: event.id,
               sponsor_user_id: sponsor.id,
               company_name: "Acme",
               contact_email: "sponsor@example.com"
             })
             |> Ash.create(tenant: workspace.id, actor: sponsor, authorize?: false)

    sponsorship
  end

  defp create_join_request(workspace, user) do
    assert {:ok, join_request} =
             JoinRequest
             |> Ash.Changeset.for_create(:create, %{
               workspace_id: workspace.id,
               user_id: user.id
             })
             |> Ash.create(actor: user)

    join_request
  end

  defp create_workspace_application(user) do
    assert {:ok, application} =
             WorkspaceApplication
             |> Ash.Changeset.for_create(:create, %{
               applicant_id: user.id,
               name: "RC App WS",
               slug: "rc-app-#{System.unique_integer([:positive])}",
               purpose: "对账规则②测试"
             })
             |> Ash.create(actor: user)

    application
  end

  # 回拨 updated_at（布置而非被测对象；SQL 直写绕开 Ash update_timestamp）
  # S8：停滞口径 = last_activity_at（最新 attempt，零 attempt 回退 inserted_at）
  defp backdate_run(run, timestamp) do
    Repo.query!("UPDATE workflow_runs SET updated_at = $1, inserted_at = $1 WHERE id = $2", [
      timestamp,
      Ecto.UUID.dump!(run.id)
    ])
  end
end
