defmodule Cgc2046.Payments.RefundCommencementRaceTest do
  @moduledoc """
  RefundCommencement 竞态与收敛的端到端守卫（#845 R1/R2；从
  payment_workers_failclosed_guard_test 与 attendance_test 拆出——两文件已超
  500 行上限）。

  注入手段：payments_orders 上的 BEFORE ROW（RETURN NULL 吞 claim）+
  AFTER STATEMENT（推进）双 trigger；两者以事务级 set_config 标记协同，
  只对真正被吞的 claim 生效（cancel/check_in 链前段的 0 行 void 语句同样
  触发语句级 trigger，无标记会把订单提前推成 refunding、令用例误走
  in_flight 分支，R2 阻断 1）。DDL 需表级排他锁，本文件 async: false 串行。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Attendance
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Repo

  require Ash.Query

  @tier_id "77777777-7777-7777-7777-777777777777"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  describe "Enrollment 自助取消退款竞态（B 侧）" do
    test "CAS 未命中且重读未收敛 → 取消回滚：报名 confirmed、订单留 paid、无退款 job" do
      admin = Fixtures.platform_admin("race-cancel-stuck-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      {_event, learner, enrollment, order} =
        paid_pricing_setup(workspace, admin, learner_suffix: "race-cancel-stuck")

      # 只拦该订单 paid→refunding 的 claim UPDATE：num_rows=0 → 已处理竞态；
      # 重读 status 仍 paid（非 refunding/refunded）→ 收敛失败分支
      inject_swallow_only(order)

      # 未收敛 = 真故障：rollback 回滚（after_action 返回 {:error, _} 会提交，
      # Ash.DataLayer.rollback 是「回滚 + 保持对外 {:error, …} 形状」的唯一
      # 手段——R2 阻断 2）；reread 未收敛时透传原始错误，code 与迁移前一致
      assert {:error,
              %Ash.Error.Invalid{
                errors: [%Cgc2046.Errors.BusinessError{code: "order_already_processed"}]
              }} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert reload_order(order).status == :paid

      assert [] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))
    end

    # 审查 R1-#1（产品拍板 A）：cancel 事务内 commence 的 claim 未命中时，
    # rollback_on_error?: false 让重读真正执行——DB 已被推进到 refunding（他路
    # 已发起）→ 收敛为 already_in_progress → 取消成功，且不重复入队（恰他路
    # 那 1 笔 job）。修复前该场景整体回滚（cancel 失败），本用例为红。
    test "事务内过期 struct + DB 已推进 refunding → 取消成功、恰 1 笔 job（R1-#1）" do
      admin = Fixtures.platform_admin("race-cancel-settled-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      {_event, learner, enrollment, order} =
        paid_pricing_setup(workspace, admin, learner_suffix: "race-cancel-settled")

      inject_swallow_and_settle(order)
      insert_he_path_job!(order)

      assert {:ok, cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: workspace.id, actor: learner)

      assert cancelled.status == :cancelled
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
      assert reload_order(order).status == :refunding

      # 恰他路那 1 笔：本侧收敛为 already_in_progress，不重复入队
      assert [%{id: he_path_job_id}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == order.id))

      assert is_integer(he_path_job_id)
    end
  end

  describe "核销即退竞态（A 侧）" do
    test "事务内过期 struct + DB 已推进 refunding → 核销成功、恰 1 笔 job（R1-#1）" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      event = deposit_event(workspace, owner, capacity: 1)
      moderator = assign_moderator(event, workspace, owner, "race-att-settled-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      inject_swallow_and_settle(order)
      insert_he_path_job!(order)

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
      moderator = assign_moderator(event, workspace, owner, "race-att-stuck-moderator")
      {_learner, enrollment, order} = confirmed_deposit_enrollment(event, workspace)

      inject_swallow_only(order)

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
  end

  describe "OfferingCancelRefundWorker 逐笔隔离" do
    test "单笔 CAS 落空：该笔回滚留 paid 无 job，批次其余照常 refunding + 入队" do
      admin = Fixtures.platform_admin("race-batch-skip-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [@tier]
        })

      paid_enrollments =
        Enum.map(["race-batch-a", "race-batch-b"], fn suffix ->
          learner = Fixtures.register_user(suffix <> "-" <> uniq())

          {:ok, enrollment} =
            Enrollment
            |> Ash.Changeset.for_create(:create_enrollment, %{
              event_id: event.id,
              user_id: learner.id,
              tier_id: @tier_id
            })
            |> Ash.create(tenant: workspace.id, actor: learner)

          {:ok, order} =
            Order
            |> Ash.Changeset.for_create(:create, %{
              enrollment_id: enrollment.id,
              provider: :wechat_native,
              out_trade_no: "oto-" <> Ecto.UUID.generate(),
              amount_cents: 19_900,
              tier_snapshot: @tier,
              expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
            })
            |> Ash.create(tenant: workspace.id, authorize?: false)

          {:ok, _} =
            order
            |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> suffix})
            |> Ash.update(tenant: workspace.id, authorize?: false)

          {:ok, _} =
            enrollment
            |> Ash.Changeset.for_update(:settle_paid, %{})
            |> Ash.update(tenant: workspace.id, authorize?: false)

          %{enrollment: enrollment, order: reload_order(order)}
        end)

      [%{order: failing}, %{order: surviving}] = paid_enrollments

      {:ok, _} =
        event
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: workspace.id, actor: admin)

      # 只拦 failing 订单的 start_refund claim UPDATE：num_rows=0 →
      # already_processed → commence 返回 {:error, reason} → log_skip。
      inject_swallow_only(failing, name: "race_one_refund_claim")

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

      assert reload_order(surviving).status == :refunding

      assert [%{args: %{"order_id" => surviving_id}}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] in [failing.id, surviving.id]))

      assert surviving_id == surviving.id
      assert reload_order(failing).status == :paid

      assert [] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == failing.id))
    end
  end

  # ── 竞态注入 ──

  # 只吞 claim、不推进（重读仍 paid = 未收敛）
  defp inject_swallow_only(order, opts \\ []) do
    name = Keyword.get(opts, :name, "race_swallow_only")

    Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_#{name}_fn() RETURNS trigger AS } <>
        ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
    )

    Repo.query!(
      ~s{CREATE TRIGGER #{name} BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
        ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
        ~s{EXECUTE FUNCTION cgc_#{name}_fn();}
    )
  end

  # 吞 claim 并由 AFTER STATEMENT 推进（模拟他路已提交；标记协同见 moduledoc）
  defp inject_swallow_and_settle(order) do
    Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_race_swallow_fn() RETURNS trigger AS } <>
        ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN PERFORM set_config('cgc.race', '1', true); RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
    )

    Repo.query!(
      ~s{CREATE TRIGGER race_swallow BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
        ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
        ~s{EXECUTE FUNCTION cgc_race_swallow_fn();}
    )

    Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_race_settle_fn() RETURNS trigger AS } <>
        ~s{$$ BEGIN IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF; IF coalesce(current_setting('cgc.race', true), '') <> '1' THEN RETURN NULL; END IF; UPDATE payments_orders SET status = 'refunding' WHERE id = '#{order.id}' AND status = 'paid'; RETURN NULL; END; $$ LANGUAGE plpgsql;}
    )

    Repo.query!(
      ~s{CREATE TRIGGER race_settle AFTER UPDATE ON payments_orders FOR EACH STATEMENT } <>
        ~s{EXECUTE FUNCTION cgc_race_settle_fn();}
    )
  end

  # 他路已入队 1 笔（竞态收敛的前提语义）
  defp insert_he_path_job!(order) do
    Repo.query!(
      ~s{INSERT INTO oban_jobs (state, queue, worker, args, priority, max_attempts, inserted_at, scheduled_at) } <>
        ~s{VALUES ('available', 'payments', 'Cgc2046.Payments.Workers.PaymentRefundWorker', } <>
        ~s{jsonb_build_object('order_id', '#{order.id}'), 0, 5, NOW(), NOW())}
    )
  end

  # ── 布置 ──

  # 定价场 paid 单（B 侧用例）：报名 confirmed + 订单 paid + 取消资格满足
  defp paid_pricing_setup(workspace, admin, opts) do
    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [@tier],
        starts_at: DateTime.add(DateTime.utc_now(), 9, :day)
      })

    learner = Fixtures.register_user(Keyword.fetch!(opts, :learner_suffix) <> "-" <> uniq())

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-race-" <> uniq()})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {event, learner, enrollment, reload_order(order)}
  end

  # ── A 侧（核销链）布置（attendance_test 同款）──

  defp deposit_event(workspace, owner, opts) do
    EventFixtures.create_event(workspace, owner, %{
      deposit_enabled: true,
      deposit_amount_cents: 6900,
      ends_at: EventFixtures.days_from_now(8),
      capacity: Keyword.get(opts, :capacity)
    })
  end

  defp confirmed_deposit_enrollment(event, workspace) do
    learner = Fixtures.register_user("race-deposit-learner-" <> uniq())
    insert_identity(learner.id, "race-learner-" <> uniq())

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
      |> Ash.create(tenant: workspace.id, actor: learner)

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

  defp assign_moderator(event, workspace, owner, prefix) do
    moderator = Fixtures.register_user(prefix)
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    moderator
  end

  defp check_in(event, code, method, actor),
    do: Attendance.check_in(event.id, code, method, actor)

  defp attendance_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM attendances WHERE enrollment_id = $1",
        [Repo.uuid!(enrollment_id)]
      )

    count
  end

  defp refund_audit_logs(order_id) do
    AdminActionLog
    |> Ash.Query.filter(action == :attendance_refund and target_id == ^order_id)
    |> Ash.read!(authorize?: false)
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

  defp reload_order(order),
    do: Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
