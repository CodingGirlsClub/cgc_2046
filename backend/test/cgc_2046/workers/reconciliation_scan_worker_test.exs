defmodule Cgc2046.Workers.ReconciliationScanWorkerTest do
  @moduledoc """
  E-10 #125 对账扫描 worker 测试（D9）。

  每规则至少一例正反：注入孤儿 → `perform_job` → Finding 命中对应规则；
  消解 → 再扫 → 空（刷新语义 D2：命中 upsert 保 first_seen_at、未命中删除）。
  规3/6 的 oban_jobs discarded 状态用 SQL 直写（approval_reminder_worker_test 先例）。
  """

  use Cgc2046Web.ConnCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo
  alias Cgc2046.Workers.NotificationWorker
  alias Cgc2046.Workers.ReconciliationScanWorker
  alias Cgc2046.Workers.SignalPublishWorker
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

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
               }, tenant: workspace.id, actor: actor)
             |> Ash.create(tenant: workspace.id, actor: actor)

    run
  end

  defp create_research_run(workspace, actor, definition, key) do
    assert {:ok, run} =
             WorkflowRun
             |> Ash.Changeset.for_create(
               :create,
               %{
                 definition_id: definition.id,
                 definition_version: definition.version,
                 input_snapshot: %{"key" => key}
               }, tenant: workspace.id, actor: actor)
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
        "SELECT id FROM oban_jobs WHERE worker = 'Cgc2046.Workers.SignalPublishWorker' " <>
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

  # ── 规4：open 且 research_enabled 但工作台无 published 教研定义 ---------------

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
      create_published_definition(workspace, admin, :research)
      EventFixtures.create_event(workspace, admin)

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end

    test "research_enabled = false 合法不命中" do
      admin = Fixtures.platform_admin("rc4-admin")
      workspace = Fixtures.create_workspace(admin)
      EventFixtures.create_event(workspace, admin, %{research_enabled: false})

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:open_entity_without_research_definition)
    end
  end

  # ── 规5：closed/cancelled 实体仍有非终态 research run ------------------------

  describe "规5 closed/cancelled 实体仍有非终态 research run" do
    test "closed event + 非终态 run → 命中；消解（run 转终态）→ 空" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      research_defn = create_published_definition(workspace, admin, :research)
      event = EventFixtures.create_event(workspace, admin)
      force_status("events", event.id, "closed")
      run = create_research_run(workspace, admin, research_defn, "event_#{event.id}")

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

    test "cancelled course + 非终态 run → 命中（course 前缀 instance key）" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      research_defn = create_published_definition(workspace, admin, :research)
      course = EventFixtures.create_course(workspace, admin)
      force_status("courses", course.id, "cancelled")
      create_research_run(workspace, admin, research_defn, "course_#{course.id}")

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = findings(:nonterminal_research_run_for_closed_entity)
      assert finding.entity_type == :course
      assert finding.entity_id == course.id
    end

    test "closed 实体但 run 已终态 → 不命中" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      research_defn = create_published_definition(workspace, admin, :research)
      event = EventFixtures.create_event(workspace, admin)
      force_status("events", event.id, "closed")
      run = create_research_run(workspace, admin, research_defn, "event_#{event.id}")
      force_run_status(run, "succeeded")

      assert :ok = perform_job(ReconciliationScanWorker, %{})
      assert [] = findings(:nonterminal_research_run_for_closed_entity)
    end

    test "open 实体 + 非终态 run → 不命中（仅 closed/cancelled 判孤儿）" do
      admin = Fixtures.platform_admin("rc5-admin")
      workspace = Fixtures.create_workspace(admin)
      research_defn = create_published_definition(workspace, admin, :research)
      event = EventFixtures.create_event(workspace, admin)
      create_research_run(workspace, admin, research_defn, "event_#{event.id}")

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
      assert finding.detail["worker"] == "Cgc2046.Workers.NotificationWorker"
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

  # ── 刷新语义（D2）与空报告 ----------------------------------------------------

  describe "刷新语义" do
    test "无孤儿 → 空报告（全表无 Finding）" do
      admin = Fixtures.platform_admin("rc-empty-admin")
      workspace = Fixtures.create_workspace(admin)

      # 教研定义 + 学习定义都具备：open 实体、confirmed 报名、learning run 齐备
      create_published_definition(workspace, admin, :research)
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
end
