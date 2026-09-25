defmodule Cgc2046.Admission.AttendanceTest do
  @moduledoc """
  U5/KTD4 核销（R6、R11；AE4 前半）：Attendance 资源与 `check_in` action。

  四面：授权（主理人 / Owner·Admin / 平台管理员放行，无关者与报名本人拒绝）、
  码定位（错码 / 非 confirmed / 跨场 / event 不存在统一 `attendance_invalid_code`）、
  幂等（同一报名第二次核销 `attendance_already_checked_in`，不落第二行、不重复审计）、
  并发（两进程赛同一报名 → 恰一行，唯一索引承担幂等）。

  并发用例的沙箱纪律（`OrderEnrollmentLockTest` 同款）：自管 owner + `unboxed_run`
  真实提交——shared sandbox 下普通进程的事务只是 savepoint，行锁与唯一索引都不可见，
  竞态不成立（`enrollment_concurrency_test` 同因同解）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Accounts.User
  alias Cgc2046.Admission.{Attendance, Enrollment}
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.MiniprogramFixtures.Barrier
  alias Cgc2046.Notifications.NotificationWorker
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.RandomCode
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo

  require Ash.Query

  describe "check_in/4 授权" do
    test "主理人核销 confirmed 报名：Attendance 一行（核销人/时间/方式）+ 审计一行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      moderator = assign_moderator(event, workspace, owner, "attendance-moderator")
      enrollment = create_confirmed_enrollment(event)

      assert {:ok, attendance} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert attendance.enrollment_id == enrollment.id
      assert attendance.event_id == event.id
      assert attendance.workspace_id == workspace.id
      assert attendance.operator_id == moderator.id
      assert attendance.method == :manual
      assert %DateTime{} = attendance.checked_in_at

      # 落库口径（非仅内存态）
      reloaded = Ash.get!(Attendance, attendance.id, authorize?: false)
      assert reloaded.checked_in_at == attendance.checked_in_at
      assert attendance_count(enrollment.id) == 1

      assert [log] = audit_logs(enrollment.id)
      assert log.action == :attendance_check_in
      assert log.actor_id == moderator.id
      assert log.target_type == :enrollment
      assert log.target_id == enrollment.id
      assert log.metadata["event_id"] == event.id
      assert log.metadata["method"] == "manual"
    end

    test "scan / manual 两种方式都落库；workspace Owner 与 Admin（非主理人）放行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)

      admin = Fixtures.register_user("attendance-ws-admin")
      Fixtures.add_member(workspace, admin, [:admin])

      owner_enrollment = create_confirmed_enrollment(event)
      admin_enrollment = create_confirmed_enrollment(event)

      assert {:ok, by_owner} = check_in(event, owner_enrollment.check_in_code, :scan, owner)
      assert by_owner.operator_id == owner.id
      assert by_owner.method == :scan

      assert {:ok, by_admin} = check_in(event, admin_enrollment.check_in_code, :manual, admin)
      assert by_admin.operator_id == admin.id
    end

    test "PlatformAdmin 非本 workspace 成员亦放行（治理兜底，与 waive_payment 同款）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      platform_admin = Fixtures.platform_admin("attendance-platform-admin")

      assert {:ok, attendance} =
               check_in(event, enrollment.check_in_code, :manual, platform_admin)

      assert attendance.operator_id == platform_admin.id
    end

    test "无关用户与报名本人核销被拒，不落行" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      learner = Fixtures.register_user("attendance-self-checkin")
      {:ok, enrollment} = create_enrollment(event, learner)
      outsider = Fixtures.register_user("attendance-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               check_in(event, enrollment.check_in_code, :manual, outsider)

      # 参与者本人不是主理人、也不是 workspace 管理角色（A3 与 A4 是两个主体）
      assert {:error, %Ash.Error.Forbidden{}} =
               check_in(event, enrollment.check_in_code, :manual, learner)

      assert attendance_count(enrollment.id) == 0
    end

    test "成员离台后核销被拒（#561 级联：指派随 membership 销毁同事务撤销）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      moderator = assign_moderator(event, workspace, owner, "attendance-cascade-mod")
      enrollment = create_confirmed_enrollment(event)

      membership = Cgc2046.Accounts.MembershipContext.membership_of(moderator, workspace.id)
      Ash.destroy!(membership, actor: owner, tenant: workspace.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               check_in(event, enrollment.check_in_code, :manual, moderator)

      assert attendance_count(enrollment.id) == 0
    end

    test "event_id 与 tenant 不一致被拒（policy 按 tenant 直读 Event，读不到即拒）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      moderator = assign_moderator(event, workspace, owner, "attendance-tenant-moderator")

      other_workspace = Fixtures.create_workspace(Fixtures.platform_admin("attendance-other-ws"))

      assert {:error, %Ash.Error.Forbidden{}} =
               Attendance
               |> Ash.Changeset.for_create(:check_in, %{
                 event_id: event.id,
                 code: enrollment.check_in_code,
                 method: :manual
               })
               |> Ash.create(tenant: other_workspace.id, actor: moderator)

      assert attendance_count(enrollment.id) == 0
    end
  end

  describe "check_in/4 码定位" do
    test "错码 / payment_pending 报名的码 / 已取消报名的码：统一 attendance_invalid_code" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      free_event = EventFixtures.create_event(workspace, owner)

      deposit_event =
        EventFixtures.create_event(workspace, owner, %{
          deposit_enabled: true,
          deposit_amount_cents: 6900,
          ends_at: EventFixtures.days_from_now(8)
        })

      # 主理人对两场都有核销资格：本组断言只测「码无效」，不掺权限噪声
      moderator = assign_moderator(free_event, workspace, owner, "attendance-code-moderator")
      {:ok, _} = Moderators.assign(deposit_event.id, workspace.id, moderator.id, owner)

      confirmed = create_confirmed_enrollment(free_event)

      learner = Fixtures.register_user("attendance-pending-learner")
      {:ok, pending} = create_enrollment(deposit_event, learner)
      assert pending.status == :payment_pending

      cancelled = create_confirmed_enrollment(free_event)

      assert {:ok, _} =
               cancelled
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner_of(cancelled))

      assert :invalid_code = reason(check_in(free_event, "000000", :manual, moderator))

      assert :invalid_code =
               reason(check_in(deposit_event, pending.check_in_code, :manual, moderator))

      assert :invalid_code =
               reason(check_in(free_event, cancelled.check_in_code, :manual, moderator))

      # 三个失败面都不落行（失败不是「半核销」）
      assert attendance_count(confirmed.id) == 0
      assert attendance_count(pending.id) == 0
      assert attendance_count(cancelled.id) == 0

      # 对照：同场 confirmed 的码仍可核销（证否「整场拒绝」）
      assert {:ok, _} = check_in(free_event, confirmed.check_in_code, :manual, moderator)
    end

    test "跨 Event 用码无效：定位按 (event_id, code)" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event_a = EventFixtures.create_event(workspace, owner, %{title: "A 场"})
      event_b = EventFixtures.create_event(workspace, owner, %{title: "B 场"})
      moderator = assign_moderator(event_a, workspace, owner, "attendance-cross-moderator")
      {:ok, _} = Moderators.assign(event_b.id, workspace.id, moderator.id, owner)

      # 钉死两场码，避免随机同码造成 flake（A 场 135790 / B 场 246801）
      RandomCode.stub_next(fn -> "135790" end)
      enrollment_a = create_confirmed_enrollment(event_a)

      RandomCode.stub_next(fn -> "246801" end)
      enrollment_b = create_confirmed_enrollment(event_b)

      assert enrollment_a.check_in_code == "135790"
      assert enrollment_b.check_in_code == "246801"

      # B 场拿 A 场的码 → 无效；A 场自己的码可用
      assert :invalid_code = reason(check_in(event_b, "135790", :manual, moderator))
      assert attendance_count(enrollment_a.id) == 0
      assert attendance_count(enrollment_b.id) == 0

      assert {:ok, _} = check_in(event_a, "135790", :manual, moderator)
      assert attendance_count(enrollment_a.id) == 1
    end

    test "event 不存在 / event_id 非法：同码返回 attendance_invalid_code" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      moderator = assign_moderator(event, workspace, owner, "attendance-missing-event-mod")

      assert :invalid_code =
               reason(check_in(%{id: Ecto.UUID.generate()}, "123456", :manual, moderator))

      assert :invalid_code = reason(check_in(%{id: "not-a-uuid"}, "123456", :manual, moderator))
    end
  end

  describe "check_in/4 幂等" do
    test "同一报名第二次核销被拒：不落第二行、不重复审计" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner)
      enrollment = create_confirmed_enrollment(event)
      moderator = assign_moderator(event, workspace, owner, "attendance-idem-moderator")

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)

      # 换核销人、换方式再核销 → 仍是同一报名的第二次核销
      assert :already_checked_in = reason(check_in(event, enrollment.check_in_code, :scan, owner))

      assert attendance_count(enrollment.id) == 1
      assert length(audit_logs(enrollment.id)) == 1
    end

    test "两进程并发核销同一报名：恰一行，败者 attendance_already_checked_in 且无审计副作用" do
      {workspace, event, moderator, enrollment, users} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("attendance-race-admin")
          workspace = Fixtures.create_workspace(admin)
          event = EventFixtures.create_event(workspace, admin)

          moderator = Fixtures.register_user("attendance-race-moderator")
          # 成员前提（#558）：主理人须为本工作台成员
          Fixtures.add_member(workspace, moderator, [:learner])
          {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, admin)

          learner = Fixtures.register_user("attendance-race-learner")
          RandomCode.stub_next(fn -> "864209" end)

          {:ok, enrollment} =
            Enrollment
            |> Ash.Changeset.for_create(:create_enrollment, %{
              event_id: event.id,
              user_id: learner.id
            })
            |> Ash.create(tenant: workspace.id, actor: learner)

          {workspace, event, moderator, enrollment, [admin, moderator, learner]}
        end)

      cleanup_on_exit(workspace, event, users)

      barrier = start_supervised!({Barrier, 2})

      results =
        [moderator, moderator]
        |> Enum.map(fn actor ->
          Task.async(fn ->
            unboxed(fn ->
              # 两进程在各自真实连接上对齐后同时发起：FOR UPDATE 串行化 + 唯一索引兜底
              Barrier.arrive(barrier)
              Attendance.check_in(event.id, enrollment.check_in_code, :manual, actor)
            end)
          end)
        end)
        |> Task.await_many(30_000)

      assert {:ok, attendance} = Enum.find(results, &match?({:ok, _}, &1))
      assert attendance.enrollment_id == enrollment.id

      assert :already_checked_in = reason(Enum.find(results, &match?({:error, _}, &1)))

      unboxed(fn ->
        assert attendance_count(enrollment.id) == 1
        # 败者不执行 after_action（LogAdminAction）：审计恰一行
        assert audit_count(enrollment.id) == 1
      end)
    end
  end

  describe "核销即退（U6/KTD6；R6、R7、R8）" do
    test "paid 押金单核销：同事务发起退款恰一笔；退款完成后报名保持 confirmed、名额不释放（AE4）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-refund-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, attendance} = check_in(event, enrollment.check_in_code, :manual, moderator)
      assert attendance.enrollment_id == enrollment.id

      # 同事务：押金单 paid → refunding + 恰一笔退款 job
      assert reload_order(order).status == :refunding
      assert refund_job_order_ids([order.id]) == [order.id]

      # 审计 actor = 核销人（KTD6）
      assert [refund_log] = refund_audit_logs(order.id)
      assert refund_log.action == :attendance_refund
      assert refund_log.actor_id == moderator.id
      assert refund_log.target_type == :order
      assert refund_log.metadata["enrollment_id"] == enrollment.id

      Fake.script!(fetch_transaction: {:ok, refunded_txn()})
      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      assert reload_order(order).status == :refunded
      # 到场者保留报名：退款完成不取消报名、不释放名额（U6 地雷一）
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert EventFixtures.ledger_occupancy(event) == 1

      assert Enum.any?(
               all_enqueued(worker: NotificationWorker),
               &(&1.args["template_key"] == "refund_succeeded" and
                   &1.args["user_id"] == enrollment.user_id)
             )
    after
      Fake.reset!()
    end

    test "入队失败时核销整体回滚：Attendance 不落库、订单不迁移、无 job（U6 地雷二）" do
      # 注入让 oban_jobs INSERT 抛异常：Oban 的嵌套事务失败后 DBConnection 断连，
      # shared sandbox 的整条外层事务随之丢失——本用例布置走 unboxed 真提交
      # （与并发用例同款纪律），注入触发器同样真落库并在收尾拆除。
      {admin, workspace, event, moderator, learner, enrollment, order} =
        unboxed(fn ->
          admin = Fixtures.platform_admin("u6-enqueue-fail-admin")
          workspace = Fixtures.create_workspace(admin)
          event = deposit_event(workspace, admin, capacity: 1)
          moderator = assign_moderator(event, workspace, admin, "u6-enqueue-fail-moderator")
          {learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)
          {admin, workspace, event, moderator, learner, enrollment, order}
        end)

      cleanup_on_exit(workspace, event, [admin, moderator, learner])
      on_exit(fn -> unboxed(&release_refund_enqueue/0) end)

      unboxed(&fail_refund_enqueue/0)

      # Ash 把 after_action 的 raise 折成错误类后 reraise（class :unknown = 真故障）
      assert_raise Ash.Error.Unknown, fn ->
        unboxed(fn -> check_in(event, enrollment.check_in_code, :manual, moderator) end)
      end

      # 整体回滚：Attendance / 审计 / 状态迁移 / job 一个都不能留
      unboxed(fn ->
        assert attendance_count(enrollment.id) == 0
        assert audit_count(enrollment.id) == 0
        assert refund_audit_logs(order.id) == []
        assert reload_order(order).status == :paid
        assert refund_job_order_ids([order.id]) == []
      end)

      # 拆除注入后可重新核销（回滚不留残骸）
      unboxed(&release_refund_enqueue/0)

      assert {:ok, _} =
               unboxed(fn -> check_in(event, enrollment.check_in_code, :manual, moderator) end)

      unboxed(fn ->
        assert reload_order(order).status == :refunding
        assert refund_job_order_ids([order.id]) == [order.id]
      end)
    end

    test "同一报名第二次核销：拒绝、订单不再迁移、无第二笔退款（AE4 后半）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-idem-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert :already_checked_in =
               reason(check_in(event, enrollment.check_in_code, :scan, owner))

      assert attendance_count(enrollment.id) == 1
      assert refund_job_order_ids([order.id]) == [order.id]
      assert length(refund_audit_logs(order.id)) == 1
      assert reload_order(order).status == :refunding
    end

    test "订单已在退还中 / 已退时核销：核销成功、无新 job、无重复退款（KTD6 良性 no-op）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 2)
      moderator = assign_moderator(event, workspace, owner, "u6-inflight-moderator")

      # 在途：管理员已发起单笔退款（paid → refunding），worker 尚未消费
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      {:ok, _} =
        order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: workspace.id, actor: owner)

      assert reload_order(order).status == :refunding
      assert refund_job_order_ids([order.id]) == [order.id]

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)
      assert refund_job_order_ids([order.id]) == [order.id]
      assert refund_audit_logs(order.id) == []

      # 已退：退款终态 + 报名仍 confirmed（到场保留）——核销同样不重复发起。
      # 该状态经退款 worker 的保留判据产生（U6），此处直接构造以钉住分派表的
      # refunded 臂（正常路径下同报名已核销，唯一索引先于分派拒绝）。
      {_learner2, enrollment2, order2} = confirmed_deposit_enrollment(event, workspace)

      Repo.query!("UPDATE payments_orders SET status = 'refunded' WHERE id = $1", [
        Repo.uuid!(order2.id)
      ])

      assert {:ok, _} = check_in(event, enrollment2.check_in_code, :manual, moderator)
      assert reload_order(order2).status == :refunded
      assert refund_job_order_ids([order2.id]) == []
      assert refund_audit_logs(order2.id) == []
    end

    test "已结算（forfeited）时核销：deposit_already_forfeited，Attendance 不落库（KTD6）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-forfeited-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      {:ok, forfeited} =
        order
        |> Ash.Changeset.for_update(:forfeit, %{})
        |> Ash.update(tenant: workspace.id, authorize?: false)

      assert forfeited.status == :forfeited

      assert :deposit_already_forfeited =
               reason(check_in(event, enrollment.check_in_code, :manual, moderator))

      # 不得静默降级为「只记到场」
      assert attendance_count(enrollment.id) == 0
      assert audit_count(enrollment.id) == 0
      assert refund_job_order_ids([order.id]) == []
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    end

    # #845 钉测：refund_failed 存量单核销走 :retry_refund 重入退款链。恰好一笔
    # job——现状靠 PaymentRefundWorker unique 兜底（retry_refund after_action
    # 入队 + 调用方手动入队各一次）；#845 D1 落地后按设计即一笔，断言不变。
    test "refund_failed 押金单核销：retry_refund 重入退款链，恰好一笔 job" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-retry-refund-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      # 渠道拒绝后未重试的存量单（015 布置同款）
      Repo.query!("UPDATE payments_orders SET status = 'refund_failed' WHERE id = $1", [
        Repo.uuid!(order.id)
      ])

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert reload_order(order).status == :refunding
      assert refund_job_order_ids([order.id]) == [order.id]
      assert length(refund_audit_logs(order.id)) == 1
    end

    # 审查 R1-#1（产品拍板 A）：check_in 事务内 commence 的 claim 未命中时，
    # rollback_on_error?: false 让重读真正执行——DB 已被推进到 refunding →
    # 收敛 already_in_progress → 核销照常成功、审计不落（非 started/retried）、
    # 不重复入队（恰他路那 1 笔）。修复前该场景整体回滚（核销失败），本用例为红。
    test "事务内过期 struct + DB 已推进 refunding → 核销成功、恰 1 笔 job（R1-#1）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-race-settled-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      # 标记协同同 B 侧（R2 阻断 1）：仅真正被吞的 claim 才触发推进，防
      # cancel/check_in 链前段 0 行语句把订单提前推成 refunding
      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_race_swallow_fn() RETURNS trigger AS } <>
          ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN PERFORM set_config('cgc.race', '1', true); RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER race_swallow BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
          ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
          ~s{EXECUTE FUNCTION cgc_race_swallow_fn();}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_race_settle_fn() RETURNS trigger AS } <>
          ~s{$$ BEGIN IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF; IF coalesce(current_setting('cgc.race', true), '') <> '1' THEN RETURN NULL; END IF; UPDATE payments_orders SET status = 'refunding' WHERE id = '#{order.id}' AND status = 'paid'; RETURN NULL; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER race_settle AFTER UPDATE ON payments_orders FOR EACH STATEMENT } <>
          ~s{EXECUTE FUNCTION cgc_race_settle_fn();}
      )

      Cgc2046.Repo.query!(
        ~s{INSERT INTO oban_jobs (state, queue, worker, args, priority, max_attempts, inserted_at, scheduled_at) } <>
          ~s{VALUES ('available', 'payments', 'Cgc2046.Payments.Workers.PaymentRefundWorker', } <>
          ~s{jsonb_build_object('order_id', '#{order.id}'), 0, 5, NOW(), NOW())}
      )

      assert {:ok, _attendance} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert attendance_count(enrollment.id) == 1
      assert reload_order(order).status == :refunding
      assert refund_audit_logs(order.id) == []

      assert [%{}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))
    end

    # 审查 R2 阻断 2 同款断言（A 侧）：竞态未收敛时核销以 {:error, …} 收场
    # （code 不丢失），Attendance 不落库、无 job——与 B 侧 rollback 形状一致
    test "竞态未收敛 → 核销 {:error, order_already_processed} 回滚：不落库、订单留 paid、无 job" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-race-stuck-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      # 只吞 claim、不推进（重读仍 paid = 未收敛）
      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_race_stuck_fn() RETURNS trigger AS } <>
          ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER race_stuck BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
          ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
          ~s{EXECUTE FUNCTION cgc_race_stuck_fn();}
      )

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Cgc2046.Errors.BusinessError{code: "order_already_processed"}]
              }} = check_in(event, enrollment.check_in_code, :manual, moderator)

      assert attendance_count(enrollment.id) == 0
      assert reload_order(order).status == :paid
      assert refund_audit_logs(order.id) == []

      assert [] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))
    end

    test "免费场核销：只记到场，不入退款链" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = EventFixtures.create_event(workspace, owner, %{capacity: 1})
      moderator = assign_moderator(event, workspace, owner, "u6-free-moderator")
      enrollment = create_confirmed_enrollment(event)
      before = all_enqueued(worker: PaymentRefundWorker) |> MapSet.new(& &1.id)

      assert {:ok, attendance} = check_in(event, enrollment.check_in_code, :manual, moderator)
      assert attendance.enrollment_id == enrollment.id
      assert attendance_count(enrollment.id) == 1

      # 免费场无押金单：核销不得新增任何退款 job
      assert Enum.reject(
               all_enqueued(worker: PaymentRefundWorker),
               &MapSet.member?(before, &1.id)
             ) ==
               []
    end

    test "核销后（截止前）参与者自助取消：无第二笔退款、名额释放（AE5 × AE4 互斥）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-self-cancel-moderator")
      {learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)

      # 退款在途（refunding，job 未消费）时自助取消：订单已非 paid，只剩名额释放
      assert {:ok, _} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
      assert EventFixtures.ledger_occupancy(event) == 0
      assert reload_order(order).status == :refunding

      # Oban unique 窗内重入同一 order 的退款任务不新增行；消费一次即终态
      assert refund_job_order_ids([order.id]) == [order.id]

      Fake.script!(fetch_transaction: {:ok, refunded_txn()})
      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})
      assert reload_order(order).status == :refunded

      # 报名已由本人取消（先核销后取消 = 只释放名额），退款不再改动报名
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
    after
      Fake.reset!()
    end

    test "先自助取消（退款在途）再尝试核销：码无效、无第二笔退款（KD3 路径互斥）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-cancel-first-moderator")
      {learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, _} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
      assert reload_order(order).status == :refunding
      assert refund_job_order_ids([order.id]) == [order.id]

      assert :invalid_code = reason(check_in(event, enrollment.check_in_code, :manual, moderator))
      assert attendance_count(enrollment.id) == 0
      assert refund_job_order_ids([order.id]) == [order.id]
    end

    test "核销后活动取消批量退（AE6）：到场单已非 paid 被跳过，其余 paid 单全退" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: nil)
      moderator = assign_moderator(event, workspace, owner, "u6-batch-moderator")
      {_learner_a, attended, attended_order} = confirmed_deposit_enrollment(event, workspace)
      {_learner_b, _not_attended, waiting_order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, _} = check_in(event, attended.check_in_code, :manual, moderator)
      assert reload_order(attended_order).status == :refunding

      {:ok, cancelled} =
        event
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: workspace.id, actor: owner)

      assert cancelled.status == :cancelled

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(
                 Cgc2046.Admission.Workers.OfferingCancelRefundWorker,
                 %{
                   type: "event.ended",
                   data: %{
                     "event_id" => event.id,
                     "idempotency_key" => "event.ended:" <> event.id
                   }
                 }
               )

      # 未核销单进入退款链；已核销（refunding）单被批量跳过，不入第二笔
      assert reload_order(waiting_order).status == :refunding
      assert reload_order(attended_order).status == :refunding

      assert refund_job_order_ids([waiting_order.id, attended_order.id]) ==
               Enum.sort([waiting_order.id, attended_order.id])
    end

    test "Attendance 读失败（模拟）：退款 worker 上抛重试，不误判未到场而取消已核销报名（fail-closed）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "u6-readfail-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)
      assert reload_order(order).status == :refunding

      Fake.script!(fetch_transaction: {:ok, refunded_txn()})

      # 表级读失败注入（DDL 事务性，用例结束自动回滚）
      Repo.query!("ALTER TABLE attendances RENAME TO attendances_u6_hidden")

      assert {:error, _} = perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      Repo.query!("ALTER TABLE attendances_u6_hidden RENAME TO attendances")

      # 退款终态已落（收尾可重入自愈），但报名绝不被错误取消、名额不释放
      assert reload_order(order).status == :refunded
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert EventFixtures.ledger_occupancy(event) == 1

      # 判据恢复后重入收敛（到场者保留 confirmed 是幂等的）
      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    after
      Fake.reset!()
    end

    test "主理人一小时内连续核销 6 笔：不产生 fund_action_burst Finding（规13 白名单不含核销审计）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: nil)
      moderator = assign_moderator(event, workspace, owner, "u6-burst-moderator")

      enrollments =
        for _ <- 1..6 do
          {_learner, enrollment, _order} = confirmed_deposit_enrollment(event, workspace)
          enrollment
        end

      for enrollment <- enrollments do
        assert {:ok, _} = check_in(event, enrollment.check_in_code, :manual, moderator)
      end

      # 同一 actor 的 6 条 :attendance_refund（阈值 5、严格大于才命中）；若被误收进
      # 白名单本断言立刻变红
      assert length(refund_audit_logs_by_actor(moderator.id)) == 6

      assert :ok = perform_job(Cgc2046.Reconciliation.ReconciliationScanWorker, %{})

      # 只钉本用例核销人的告警面（规 13 是全局扫描：并行单元/历史残留的其它 actor
      # 告警与本契约无关）；误收白名单时本 actor 立刻命中
      assert Finding
             |> Ash.Query.filter(rule == :fund_action_burst and entity_id == ^moderator.id)
             |> Ash.read!(authorize?: false) == []
    end
  end

  # ── 布置 ──

  defp create_enrollment(%{id: id, workspace_id: workspace_id}, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: id, user_id: user.id})
    |> Ash.create(tenant: workspace_id, actor: user)
  end

  defp create_confirmed_enrollment(event) do
    learner = Fixtures.register_user("attendance-learner")

    {:ok, enrollment} = create_enrollment(event, learner)
    assert enrollment.status == :confirmed
    enrollment
  end

  defp assign_moderator(event, workspace, owner, prefix) do
    moderator = Fixtures.register_user(prefix)
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    moderator
  end

  defp learner_of(enrollment),
    do: Ash.get!(User, enrollment.user_id, authorize?: false)

  defp check_in(event, code, method, actor),
    do: Attendance.check_in(event.id, code, method, actor)

  # 错误形状解包：Ash 把 BusinessError 收在 %Ash.Error.Invalid{errors: [...]} 内
  defp reason({:error, %Ash.Error.Invalid{errors: errors}}), do: reason_of(errors)
  defp reason({:error, %BusinessError{} = error}), do: reason_of([error])
  defp reason(other), do: other

  defp reason_of(errors) do
    case Enum.find(errors, &match?(%BusinessError{}, &1)) do
      %BusinessError{code: "attendance_invalid_code"} -> :invalid_code
      %BusinessError{code: "attendance_already_checked_in"} -> :already_checked_in
      %BusinessError{code: "deposit_already_forfeited"} -> :deposit_already_forfeited
      other -> other
    end
  end

  defp audit_logs(enrollment_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :attendance_check_in and target_id == ^enrollment_id)
    |> Ash.read!(authorize?: false)
  end

  defp attendance_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM attendances WHERE enrollment_id = $1",
        [enrollment_id && Repo.uuid!(enrollment_id)]
      )

    count
  end

  defp audit_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM admin_action_logs WHERE action = 'attendance_check_in' AND target_id = $1",
        [Repo.uuid!(enrollment_id)]
      )

    count
  end

  # ── U6 押金布置 ──

  defp deposit_event(workspace, owner, opts) do
    EventFixtures.create_event(workspace, owner, %{
      deposit_enabled: true,
      deposit_amount_cents: 6900,
      ends_at: EventFixtures.days_from_now(8),
      capacity: Keyword.get(opts, :capacity)
    })
  end

  # 押金场 confirmed 报名 + paid 押金单（U1 下单链的手工等价物——押金单金额源属 U2，
  # 本文件只依赖「一份已收押金的 confirmed 报名」这一状态）
  defp confirmed_deposit_enrollment(event, workspace) do
    learner = Fixtures.register_user("u6-deposit-learner-" <> uniq())
    insert_identity(learner.id, "u6-learner-" <> uniq())

    {:ok, enrollment} = create_enrollment(event, learner)
    assert enrollment.status == :payment_pending

    order = paid_deposit_order(enrollment, workspace)

    {:ok, confirmed} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    assert confirmed.status == :confirmed
    {learner, confirmed, order}
  end

  defp paid_deposit_order(enrollment, workspace) do
    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        order_kind: :deposit,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 6900,
        tier_snapshot: %{},
        expire_at: DateTime.add(DateTime.utc_now(), 1, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> uniq()})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    paid
  end

  defp refunded_txn,
    do: %{status: :refunded, amount_cents: 6900, transaction_id: "txn-deposit-refunded"}

  defp reload_order(order),
    do: Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)

  defp refund_audit_logs(order_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :attendance_refund and target_id == ^order_id)
    |> Ash.read!(authorize?: false)
  end

  defp refund_audit_logs_by_actor(actor_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :attendance_refund and actor_id == ^actor_id)
    |> Ash.read!(authorize?: false)
  end

  # 退款 job 断言一律按「本用例的订单」收敛：同一测试库可能被并行单元真提交
  # 过 job（unboxed 布置），全局计数会串台——按 order_id 过滤后每笔订单恰一条
  # 仍是被钉死的契约（重复入队会被计数抓住）。
  defp refund_job_order_ids(order_ids) do
    all_enqueued(worker: PaymentRefundWorker)
    |> Enum.map(& &1.args["order_id"])
    |> Enum.filter(&(&1 in order_ids))
    |> Enum.sort()
  end

  defp insert_identity(user_id, uid) do
    Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'wechat', $1, $2, NOW(), NOW())
      """,
      [uid, Ecto.UUID.dump!(user_id)]
    )
  end

  # Oban 入队失败注入（KTD6 地雷二）：oban_jobs 上的 BEFORE INSERT trigger 让
  # `Oban.insert!` 抛异常——证明「raise 型入队 → 整事务回滚」。用例在 unboxed
  # 模式真落注入（DDL 需表级排他锁 → 本文件 async: false），收尾必拆。
  defp fail_refund_enqueue do
    Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_test_block_refund_enqueue() RETURNS trigger AS } <>
        ~s{$$ BEGIN RAISE EXCEPTION 'test injected oban enqueue failure'; END; $$ LANGUAGE plpgsql;}
    )

    Repo.query!(
      ~s{CREATE TRIGGER block_refund_enqueue BEFORE INSERT ON oban_jobs FOR EACH ROW } <>
        ~s{WHEN (NEW.worker = 'Cgc2046.Payments.Workers.PaymentRefundWorker') } <>
        ~s{EXECUTE FUNCTION cgc_test_block_refund_enqueue();}
    )
  end

  defp release_refund_enqueue do
    Repo.query!("DROP TRIGGER IF EXISTS block_refund_enqueue ON oban_jobs")
    Repo.query!("DROP FUNCTION IF EXISTS cgc_test_block_refund_enqueue")
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)

  # ── 并发用例布置（OrderEnrollmentLockTest 同款：先释放 sandbox 事务，再 unboxed 真删）──

  defp cleanup_on_exit(workspace, event, users) do
    on_exit(fn ->
      # 先结束 shared sandbox 事务：应用级订阅方/审计写在事务内的 workspaces 外键
      # KEY SHARE 锁不释放，unboxed DELETE workspaces 会阻塞到连接超时（owner Agent
      # 不 kill——DataCase 的 on_exit 仍要 stop_owner，二次 stop 会 :noproc 崩）。
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      unboxed(fn ->
        Repo.query!("DELETE FROM attendances WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        # U6（核销即退）用例真提交产生的资金侧残留：job 先删（无外键、按 args 定位），
        # 再删押金单，最后才轮到 enrollments/users
        Repo.query!(
          "DELETE FROM oban_jobs WHERE args->>'order_id' IN (SELECT id::text FROM payments_orders WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!(
          "DELETE FROM oban_jobs WHERE args->>'user_id' = ANY($1)",
          [Enum.map(users, &to_string(&1.id))]
        )

        Repo.query!("DELETE FROM payments_orders WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE action IN ('attendance_check_in', 'attendance_refund') AND metadata->>'event_id' = $1",
          [event.id]
        )

        Repo.query!("DELETE FROM enrollments WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!("DELETE FROM admission_capacity_ledgers WHERE offering_id = $1", [
          Repo.uuid!(event.id)
        ])

        Repo.query!("DELETE FROM event_moderators WHERE event_id = $1", [Repo.uuid!(event.id)])

        Repo.query!(
          "DELETE FROM membership_roles WHERE membership_id IN (SELECT id FROM workspace_memberships WHERE workspace_id = $1)",
          [Repo.uuid!(workspace.id)]
        )

        Repo.query!("DELETE FROM workspace_memberships WHERE workspace_id = $1", [
          Repo.uuid!(workspace.id)
        ])

        Repo.query!("DELETE FROM events WHERE workspace_id = $1", [Repo.uuid!(workspace.id)])

        Repo.query!(
          "DELETE FROM admin_action_logs WHERE target_type = 'workspace' AND target_id = $1",
          [Repo.uuid!(workspace.id)]
        )

        # #348：workspace seed 落 workflow_definitions（FK）——先清子表再删 workspace
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
