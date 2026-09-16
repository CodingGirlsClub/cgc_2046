defmodule Cgc2046.Payments.DepositForfeitWorkerTest do
  @moduledoc """
  U8/KTD7、KTD8、KTD11 —— 押金 no-show 结算 worker（R8、R9；AE7）。

  覆盖：结算锚点（`ends_at` + 48h）与 `closed` 门、锁内 Attendance 重查、
  `paid → forfeited` CAS 幂等与批量审计（非零计数）、无锚场 Finding 的刷新语义、
  与核销/退款路径的两路竞态（恰一方成功）、内部 `forfeit` action 对外部角色的
  拒绝、crontab 与规 6 死信白名单注册。

  布置纪律：报名与付款必须在活动 open 期完成（`create_enrollment` 要求 target
  open），关闭/取消放在布置末尾——与生产时序一致（先收款、活动结束、T+48h 结算）。

  沙箱纪律：结算用例走 shared sandbox（每例回滚）；真并发用例同 `attendance_test`
  （自管 owner + `unboxed_run` 真实提交，共享事务下的行锁与唯一索引不可见）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.{Attendance, Enrollment}
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.{DepositForfeitWorker, PaymentRefundWorker}
  alias Cgc2046.Reconciliation.{Finding, ReconciliationScanWorker}
  alias Cgc2046.Repo

  @deposit_cents 6900

  describe "no-show 结算（AE7）" do
    test "closed 场 ends_at + 49h：3 笔 paid 未核销 → 3 笔 forfeited + 一条审计计数 3" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))

      enrollments =
        for i <- 1..3 do
          {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-ae7-#{i}")
          enrollment
        end

      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      # 落库口径：3 笔全部终态不退
      for enrollment <- enrollments do
        assert deposit_order(enrollment).status == :forfeited
      end

      # 批量审计：一条（按 event 聚合）、计数 3、actor = nil 系统语义
      assert [log] = audit_logs(event.id)
      assert log.action == :deposit_forfeit
      assert log.actor_id == nil
      assert log.target_type == :event
      assert log.target_id == event.id
      assert log.metadata["forfeited_orders"] == 3
      assert log.metadata["forfeited_cents"] == 3 * @deposit_cents

      assert Enum.sort(log.metadata["order_ids"]) ==
               enrollments |> Enum.map(&deposit_order(&1).id) |> Enum.sort()

      # AE7 对账导出：没收额只进 forfeited 桶，不重复计 collected
      stats = payment_stats(workspace, owner)
      assert stats.forfeited_cents == 3 * @deposit_cents
      assert stats.collected_cents == 0
    end

    test "未到结算点（ends_at + 47h）→ 零动作" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(47))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-not-yet")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :paid
      assert audit_logs(event.id) == []
    end

    test "重投（同拍第二遍）→ 零新增：状态与审计都不变" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-replay")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})
      fresh = deposit_order(enrollment)
      assert fresh.status == :forfeited
      assert length(audit_logs(event.id)) == 1

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).updated_at == fresh.updated_at
      assert length(audit_logs(event.id)) == 1
    end
  end

  describe "结算门（KTD7：仅 closed 场 + ends_at 锚）" do
    test "open 场（未 close）ends_at 已过 48h → 零动作" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-open")

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :paid
      assert audit_logs(event.id) == []
    end

    test "cancelled 场 → 零动作（由批量退接管，不没收）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-cancelled")

      assert {:ok, _cancelled} =
               event
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(actor: owner, tenant: workspace.id)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :paid
      assert audit_logs(event.id) == []
    end

    test "活跃场次多次状态写入刷新 updated_at → 不影响结算时机（锚只认 ends_at）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-updated-at")
      event = close_event(event, owner, workspace)

      # close 之后连续编辑（每次把 events.updated_at 刷成现在）：若锚点是
      # updated_at，结算会被无限推迟（本仓两次「越活跃越不告警」事故的同款形状）
      for i <- 1..3 do
        assert {:ok, _} =
                 event
                 |> Ash.Changeset.for_update(:update, %{title: "U8 anchor #{i}"})
                 |> Ash.update(actor: owner, tenant: workspace.id)
      end

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :forfeited
      assert length(audit_logs(event.id)) == 1
    end

    test "closed 场调用 Event.cancel → 状态守卫拒绝，没收单与批量退无交集" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-closed-cancel")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})
      order = deposit_order(enrollment)
      assert order.status == :forfeited

      # closed 是终态（D4）：Event.cancel 源态仅 open，批量退入口不会被打开
      assert {:error, _reason} =
               event
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(actor: owner, tenant: workspace.id)

      refute_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})
      assert deposit_order(enrollment).status == :forfeited
    end
  end

  describe "Attendance 互斥（KTD8 跨表竞态）" do
    test "paid 单已有 Attendance（竞态残影布置）：候选下推即排除，订单保持不动" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-checked-in")
      event = close_event(event, owner, workspace)
      insert_attendance(event, enrollment, owner.id)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :paid
      assert audit_logs(event.id) == []
    end

    test "核销已落（真实 check-in）：sweep 不没收已到场者的押金" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-real-check-in")
      moderator = assign_moderator(event, workspace, owner, "u8-check-in-moderator")
      event = close_event(event, owner, workspace)

      assert {:ok, _attendance} =
               Attendance.check_in(event.id, enrollment.check_in_code, :manual, moderator)

      assert attendance_count(enrollment.id) == 1

      assert :ok = perform_job(DepositForfeitWorker, %{})

      # 核销即退把押金单送进退款链（U6/KTD6）：单已离 paid，sweep 无从没收
      assert deposit_order(enrollment).status in [:refunding, :refunded]
      assert attendance_count(enrollment.id) == 1
      assert audit_logs(event.id) == []
    end

    test "没收已落：核销败方收到 deposit_already_forfeited，Attendance 不落库" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-forfeit-wins")
      moderator = assign_moderator(event, workspace, owner, "u8-late-moderator")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})
      assert deposit_order(enrollment).status == :forfeited

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Attendance.check_in(event.id, enrollment.check_in_code, :manual, moderator)

      # 不静默只记到场：显式业务错误 + 报名无 Attendance 行
      assert Enum.any?(errors, &match?(%BusinessError{code: "deposit_already_forfeited"}, &1))
      assert attendance_count(enrollment.id) == 0
    end

    test "同瞬间并发（真实提交）：Enrollment 行锁串行化，恰一方成功" do
      {workspace, event, moderator, enrollment, users} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("u8-race-admin")
          workspace = Fixtures.create_workspace(admin)
          event = deposit_event(workspace, admin, hours_ago(49))

          moderator = Fixtures.register_user("u8-race-moderator")
          # 成员前提（#558）：主理人须为本工作台成员
          Fixtures.add_member(workspace, moderator, [:learner])
          {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, admin)

          learner = Fixtures.register_user("u8-race-learner")
          {_learner, enrollment} = paid_deposit_enrollment(event, workspace, learner: learner)
          event = close_event(event, admin, workspace)

          {workspace, event, moderator, enrollment, [admin, moderator, learner]}
        end)

      cleanup_on_exit(workspace, event, users)

      barrier = start_supervised!({Barrier, 2})

      [sweep_result, check_in_result] =
        [
          fn -> perform_job(DepositForfeitWorker, %{}) end,
          fn -> Attendance.check_in(event.id, enrollment.check_in_code, :manual, moderator) end
        ]
        |> Enum.map(fn op ->
          Task.async(fn ->
            unboxed(fn ->
              Barrier.arrive(barrier)
              op.()
            end)
          end)
        end)
        |> Task.await_many(30_000)

      assert sweep_result == :ok

      unboxed(fn ->
        status = deposit_order(enrollment).status
        attendance_rows = attendance_count(enrollment.id)

        if status == :forfeited do
          # 没收先落：核销拿锁后看到终态 → 显式业务错误，Attendance 回滚
          assert attendance_rows == 0
          assert deposit_already_forfeited?(check_in_result)
        else
          # 核销先落：Attendance 在，押金单交给核销即退链（refunding）或尚未流转
          # （paid，U6 之前的口径），sweep 不没收
          assert attendance_rows == 1
          assert status in [:paid, :refunding]
        end
      end)
    end
  end

  describe "退款路径互斥（KTD8 单一仲裁点）" do
    test "押金单已被退款路径接管（start_refund 先落）→ 零动作、终态唯一" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-refund-wins")
      event = close_event(event, owner, workspace)

      # 自助取消 / 批量退 / 核销即退共用同一 start_refund CAS（他路先接管）
      order = deposit_order(enrollment)

      assert {:ok, _refunding} =
               order
               |> Ash.Changeset.for_update(:start_refund, %{})
               |> Ash.update(authorize?: false, tenant: workspace.id)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert deposit_order(enrollment).status == :refunding
      assert audit_logs(event.id) == []
    end

    test "没收终态不被自助取消改写：取消只释放名额、不再产生资金动作" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-cancel-after")
      _closed = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})
      order = deposit_order(enrollment)
      assert order.status == :forfeited

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(actor: learner, tenant: workspace.id)

      assert cancelled.status == :cancelled
      assert deposit_order(enrollment).status == :forfeited
      refute_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})
    end
  end

  describe "无锚场防御（KTD7：绝不静默滞留）" do
    test "closed 且 ends_at 为空 → 不结算，产出一条 deposit_settlement_unanchored Finding（重投不重复）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = unanchored_event(workspace, owner)
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-unanchored")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      # 不结算（锚点缺失不是「到点」）
      assert deposit_order(enrollment).status == :paid
      assert audit_logs(event.id) == []

      assert [finding] = findings(event.id)
      assert finding.rule == :deposit_settlement_unanchored
      assert finding.entity_type == :event
      assert finding.entity_id == event.id
      assert finding.workspace_id == workspace.id
      assert finding.detail["reason"] == "closed_event_without_ends_at"
      assert finding.detail["paid_deposit_orders"] == 1
      assert finding.detail["paid_cents"] == @deposit_cents

      # 幂等：重投刷新 last_seen_at，不新增第二行
      first_seen_at = finding.first_seen_at
      assert :ok = perform_job(DepositForfeitWorker, %{})
      assert [again] = findings(event.id)
      assert again.id == finding.id
      assert again.first_seen_at == first_seen_at
    end

    test "锚点补回后 Finding 自消（「未命中即删」刷新语义）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = unanchored_event(workspace, owner)
      {_learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-anchor-back")
      event = close_event(event, owner, workspace)

      assert :ok = perform_job(DepositForfeitWorker, %{})
      assert [_finding] = findings(event.id)

      # 补锚（旁路数据修复）：ends_at 过点 → 下拍既结算又删除无锚 finding
      assert {:ok, _} =
               event
               |> Ash.Changeset.for_update(:update, %{ends_at: hours_ago(49)})
               |> Ash.update(actor: owner, tenant: workspace.id)

      assert :ok = perform_job(DepositForfeitWorker, %{})

      assert findings(event.id) == []
      assert deposit_order(enrollment).status == :forfeited
    end
  end

  describe "内部 action 与注册面" do
    test "外部角色（参与者 / Owner / 平台管理员）调用 forfeit → 无授权 policy 被拒" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, hours_ago(49))
      {learner, enrollment} = paid_deposit_enrollment(event, workspace, "u8-external")
      platform_admin = Fixtures.platform_admin("u8-platform-admin")

      for actor <- [learner, owner, platform_admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 deposit_order(enrollment)
                 |> Ash.Changeset.for_update(:forfeit, %{})
                 |> Ash.update(actor: actor, tenant: workspace.id)

        assert deposit_order(enrollment).status == :paid
      end

      # 对外 GraphQL 面也没有该 mutation（内部专用：仅 worker authorize?: false）
      refute File.read!("priv/graphql/schema.graphql") =~ "forfeitOrder"
    end

    test "crontab 每 10 分钟注册 + 规 6 死信白名单含新 worker 名" do
      plugins = Application.get_env(:cgc_2046, Oban)[:plugins]
      assert {Oban.Plugins.Cron, cron_opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
      crontab = Keyword.fetch!(cron_opts, :crontab)

      assert {"*/10 * * * *", DepositForfeitWorker} in crontab

      # 规 6 白名单三处字面量（@dead_letter_workers + 两处规则描述）同源：钉住
      # 「新 worker 名进白名单」与「白名单模块真实存在」（后者由对账测试遍历断言）
      assert "Cgc2046.Payments.Workers.DepositForfeitWorker" in ReconciliationScanWorker.dead_letter_workers()

      assert Code.ensure_loaded?(DepositForfeitWorker)
    end

    test "规 6 死信窗口内含本 worker：discarded job → 对账 finding 可见" do
      {:ok, job} = Oban.insert(DepositForfeitWorker.new(%{"probe" => "u8-dead-letter"}))

      Repo.query!("UPDATE oban_jobs SET state = 'discarded' WHERE id = $1", [job.id])

      assert :ok = perform_job(ReconciliationScanWorker, %{})

      assert [finding] = dead_letter_findings(job.id)
      assert finding.entity_type == :oban_job
      assert finding.entity_id == to_string(job.id)
      assert finding.detail["worker"] == "Cgc2046.Payments.Workers.DepositForfeitWorker"
      assert is_nil(finding.workspace_id)
    end
  end

  # ── 布置 ──

  defp deposit_event(workspace, owner, ends_at) do
    EventFixtures.create_event(workspace, owner, %{
      deposit_enabled: true,
      deposit_amount_cents: @deposit_cents,
      ends_at: ends_at
    })
  end

  # 无锚场（KTD7 防御面）：`ends_at` 为空 + 名下押金单——`deposit_enabled` 的
  # ends_at 必填校验下生产不可达，故不开启押金建场，报名与订单直接布置。
  defp unanchored_event(workspace, owner), do: EventFixtures.create_event(workspace, owner)

  defp close_event(event, owner, workspace) do
    {:ok, closed} =
      event
      |> Ash.Changeset.for_update(:close, %{})
      |> Ash.update(actor: owner, tenant: workspace.id)

    closed
  end

  # 生产态布置：报名落 payment_pending → 押金单 pending → mark_paid → settle_paid
  # 落 confirmed（U1/KTD2 的收取链；付款后报名才可被核销）。
  defp paid_deposit_enrollment(event, workspace, learner: learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        order_kind: :deposit,
        provider: :wechat_native,
        out_trade_no: Ecto.UUID.generate(),
        amount_cents: @deposit_cents,
        tier_snapshot: %{},
        expire_at: DateTime.add(DateTime.utc_now(), 3600)
      })
      |> Ash.create!(authorize?: false, tenant: workspace.id)
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: Ecto.UUID.generate()})
      |> Ash.update!(authorize?: false, tenant: workspace.id)

    confirmed = confirm_enrollment(enrollment, workspace)

    assert order.status == :paid
    assert confirmed.status == :confirmed

    {learner, confirmed}
  end

  defp paid_deposit_enrollment(event, workspace, name) when is_binary(name) do
    paid_deposit_enrollment(event, workspace, learner: Fixtures.register_user(name))
  end

  # 免费场报名（无锚场防御的布置）直接落 confirmed；押金场走 settle_paid CAS。
  defp confirm_enrollment(%{status: :confirmed} = enrollment, _workspace), do: enrollment

  defp confirm_enrollment(enrollment, workspace) do
    {:ok, confirmed} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(authorize?: false, tenant: workspace.id)

    confirmed
  end

  # 布置「paid 单 + 已有 Attendance」——该组合在核销即退链下只在竞态窗口内可达，
  # 无域 action 可复现（核销成功即把订单送进退款链），故直接落行；被测对象是
  # worker 的候选下推/锁内重查判定。
  defp insert_attendance(event, enrollment, operator_id) do
    Repo.query!(
      """
      INSERT INTO attendances
        (workspace_id, enrollment_id, event_id, operator_id, checked_in_at, method,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, (NOW() AT TIME ZONE 'UTC'), 'manual',
              (NOW() AT TIME ZONE 'UTC'), (NOW() AT TIME ZONE 'UTC'))
      """,
      [
        Repo.uuid!(event.workspace_id),
        Repo.uuid!(enrollment.id),
        Repo.uuid!(event.id),
        Repo.uuid!(operator_id)
      ]
    )
  end

  defp assign_moderator(event, workspace, owner, prefix) do
    moderator = Fixtures.register_user(prefix)
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    moderator
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

  # ── 读面 ──

  defp deposit_order(enrollment) do
    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment.id and order_kind == :deposit)
    |> Ash.read_one!(authorize?: false)
  end

  defp audit_logs(event_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :deposit_forfeit and target_id == ^event_id)
    |> Ash.read!(authorize?: false)
  end

  defp findings(event_id) do
    Finding
    |> Ash.Query.filter(rule == :deposit_settlement_unanchored and entity_id == ^event_id)
    |> Ash.read!(authorize?: false)
  end

  defp dead_letter_findings(job_id) do
    Finding
    |> Ash.Query.filter(rule == :dead_letter_job and entity_id == ^to_string(job_id))
    |> Ash.read!(authorize?: false)
  end

  defp attendance_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM attendances WHERE enrollment_id = $1", [
        Repo.uuid!(enrollment_id)
      ])

    count
  end

  defp payment_stats(workspace, actor) do
    {:ok, stats} =
      Order
      |> Ash.ActionInput.for_action(:workspace_payment_stats, %{workspace_id: workspace.id})
      |> Ash.run_action(actor: actor, tenant: workspace.id)

    stats
  end

  defp deposit_already_forfeited?({:error, %Ash.Error.Invalid{errors: errors}}) do
    Enum.any?(errors, &match?(%BusinessError{code: "deposit_already_forfeited"}, &1))
  end

  defp deposit_already_forfeited?(_other), do: false

  # ── 真并发用例布置（attendance_test 同款：自管 owner + unboxed 真实提交）──

  defp cleanup_on_exit(workspace, event, users) do
    on_exit(fn ->
      # 先结束 shared sandbox 事务：应用级订阅方/审计写在事务内的外键 KEY SHARE
      # 锁不释放，unboxed DELETE workspaces 会阻塞到连接超时。
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      unboxed(fn ->
        Repo.query!("DELETE FROM attendances WHERE event_id = $1", [Repo.uuid!(event.id)])

        # 真实提交的 job 不随工作区级联：显式清理，避免污染套件内
        # `all_enqueued(worker: ...) == []` 类全局断言（核销即退的退款 job 与
        # event.ended 的 outbox job 都是本用例真实提交的）
        Repo.query!(
          """
          DELETE FROM oban_jobs
          WHERE (worker = 'Cgc2046.Payments.Workers.PaymentRefundWorker'
                 AND args->>'order_id' IN (
                   SELECT id::text FROM payments_orders WHERE workspace_id = $1
                 ))
             OR (worker = 'Cgc2046.Workflows.SignalPublishWorker'
                 AND args->'data'->>'event_id' = $2)
          """,
          [Repo.uuid!(workspace.id), event.id]
        )

        Repo.query!("DELETE FROM reconciliation_findings WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'event' AND target_id = $1",
          [
            Repo.uuid!(event.id)
          ]
        )

        Repo.query!("DELETE FROM payments_orders WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM enrollments WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!("DELETE FROM admission_capacity_ledgers WHERE offering_id = $1", [
          Repo.uuid!(event.id)
        ])

        Repo.query!("DELETE FROM event_moderators WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!("DELETE FROM events WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        # workspace seed 落 workflow_definitions（FK）——先清子表再删 workspace
        Repo.query!("DELETE FROM workflow_definitions WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM workspaces WHERE id = $1", [Repo.uuid!(workspace.id)])

        Enum.each(users, fn user ->
          Repo.query!("DELETE FROM users WHERE id = $1", [Repo.uuid!(user.id)])
        end)
      end)
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
