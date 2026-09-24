defmodule Cgc2046.Payments.Workers.PaymentWorkersFailclosedGuardTest do
  @moduledoc """
  015：payments worker 错误路径 fail-open 收口的故障注入测试（串行文件）。

  覆盖四个「错误绝不吞」守卫，注入手段均为**沙箱事务内 DDL**（事务性，测试
  结束自动回滚）。DDL 注入需要表级 ACCESS EXCLUSIVE 锁，故本文件 `async: false`
  串行执行——不要把这类测试迁进 async: true 文件（与并行测试在 payments_orders
  等热表上互等甚至死锁，复审 F2）：

  - `PaymentRefundWorker.waived?/1` 读 AdminActionLog 失败 → `{:error, reason}`
    上抛而非折叠为 false（false 会把免缴学员的已确认报名错误取消，不可逆）；
  - `PaymentSettlementWorker` 落账 DB 瞬断（mark_paid 失败且 reload 仍 pending）
    → `{:error, :order_still_pending}` 上抛重试，绝不 mark_processed 永久丢单；
  - `PaymentExpiryWorker` 硬失败（DB 类错误）→ `{:error, :expire_hard_failure}`
    整拍上抛走 Oban 重试（毒记录不再每分钟静默重试到永远）；
  - `PaymentExpiryWorker` CAS 未命中（BEFORE UPDATE RETURN NULL 确定性模拟
    num_rows=0）→ 预期竞态 `:skip`，整拍仍 `:ok`。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Payments.Workers.PaymentExpiryWorker
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker

  require Ash.Query

  @tier_id "77777777-7777-7777-7777-777777777777"
  @tier %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}

  describe "PaymentRefundWorker waived? 读失败守卫" do
    test "读失败 → {:error} 不取消免缴报名；恢复后重入按免缴语义保留 confirmed" do
      %{enrollment: enrollment, order: order} = paid_order_setup()

      # 免缴审计行（waived? 的判定事实源；真实写入在 waive_payment action，
      # 此处等效布置——审计行存在 ⇔ 免缴先落，KTD4）
      {:ok, _} =
        Cgc2046.Repo.query(
          "INSERT INTO admin_action_logs " <>
            "(id, action, target_type, target_id, result, metadata, inserted_at) " <>
            "VALUES (gen_random_uuid(), 'waive_payment', 'enrollment', $1, 'success', '{}'::jsonb, NOW())",
          [Cgc2046.Repo.uuid!(enrollment.id)]
        )

      # 订单推到 refunded（报名收尾窗口：confirmed 未处理——F-B 同款布置）
      to_refunded(order)

      # 注入：waived? 的读失败（改名表；沙箱事务内 DDL，测试结束自动回滚）
      Cgc2046.Repo.query!("ALTER TABLE admin_action_logs RENAME TO admin_action_logs_blocked")

      assert {:error, _read_failure} =
               perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      # 守卫生效：读失败绝不折叠为 false——免缴报名未被错误取消
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

      # 解除 → 重试经 :refunded 状态门收敛：免缴语义本体 = 钱退、报名保持 confirmed
      Cgc2046.Repo.query!("ALTER TABLE admin_action_logs_blocked RENAME TO admin_action_logs")

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => order.id})

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert reload_order(order).status == :refunded
    end
  end

  describe "PaymentSettlementWorker 落账 DB 瞬断守卫" do
    test "mark_paid 失败且订单仍 pending → {:error, :order_still_pending}，绝不 mark_processed" do
      # pending 单：落账链尚未开始（paid_order_setup 的订单已是 paid，不适用）
      %{order: order} = base_setup()
      stub_channel_paid(order)

      # 注入 mark_paid 的 CAS UPDATE 失败（DB 类错误形状）：pending→paid 被
      # 数据库层拒绝。此时渠道查单已确认有款且金额相符——旧实现会走 `other`
      # 分支 mark_processed 永久丢单（已收款、不落账、不退款、不重试）。
      inject_trigger(
        "block_mark_paid",
        "payments_orders",
        "WHEN (OLD.status = 'pending' AND NEW.status = 'paid')",
        raise?: true
      )

      assert {:error, :order_still_pending} = perform_settlement(order)

      # 事件未被消费（Oban 会重试），订单仍 pending，未误触自动退款
      assert event_for(order).status != :processed

      refute_enqueued(worker: PaymentRefundWorker)

      # 解除注入 → Oban 重试 → 完整落账收敛
      drop_trigger("block_mark_paid", "payments_orders")

      assert :ok = perform_settlement(order)
      assert reload_order(order).status == :paid
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :confirmed
    end

    # F-I（自 payment_settlement_worker_test 迁入）：报名 CAS 的 trigger 注入在
    # enrollments 热表上做 DDL，async 文件里与并行测试互等死锁（CI 40P01 实证，
    # PR #548/#549 三连败）——与 015 同款纪律，集中在本串行文件。
    test "F-I 报名 CAS DB 错误：不误触自动退款，上抛走 Oban 重试；解除后自愈收敛" do
      %{enrollment: enrollment, order: order} = base_setup()
      stub_channel_paid(order)

      # trigger 注入 settle_paid 的 UPDATE 失败（DB 类错误形状）：
      # payment_pending→confirmed 的状态 CAS 被数据库层拒绝
      inject_trigger(
        "block_settle",
        "enrollments",
        "WHEN (OLD.status = 'payment_pending' AND NEW.status = 'confirmed')",
        raise?: true
      )

      assert {:error, _db_error} = perform_settlement(order)

      # 占位完好的正常收款不得被 DB 瞬断误判为「报名已流转」而触发自动退款
      refute_enqueued(worker: PaymentRefundWorker)

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :payment_pending

      # 解除注入 → Oban 重试 → 半落账路径自愈收敛（F-A 联动）
      drop_trigger("block_settle", "enrollments")

      assert :ok = perform_settlement(order)
      assert reload_order(order).status == :paid
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
    end
  end

  describe "PaymentExpiryWorker 错误二分类" do
    test "DB 类硬失败 → {:error, :expire_hard_failure} 整拍重试；解除后收敛 expired" do
      %{order: order} = expired_order_setup()

      # 注入：订单 CAS（pending→expired）被数据库层拒绝 → 非 order_already_processed
      # 的 BusinessError → 硬失败。旧实现折叠为 :skip，毒记录每分钟静默重试到永远。
      inject_trigger(
        "block_expire",
        "payments_orders",
        "WHEN (OLD.status = 'pending' AND NEW.status = 'expired')",
        raise?: true
      )

      assert {:error, :expire_hard_failure} = perform_job(PaymentExpiryWorker, %{})

      # 订单仍 pending 占位，等重试收敛
      assert reload_order(order).status == :pending

      drop_trigger("block_expire", "payments_orders")

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order).status == :expired
    end

    test "CAS 未命中（num_rows=0 确定性模拟）→ 预期竞态 :skip，整拍 :ok" do
      %{order: order} = expired_order_setup()

      # BEFORE UPDATE RETURN NULL 静默吞掉 UPDATE：claim/4 得 num_rows=0 →
      # BusinessError code "order_already_processed" → 预期竞态分支。
      inject_trigger(
        "swallow_expire",
        "payments_orders",
        "WHEN (OLD.status = 'pending' AND NEW.status = 'expired')",
        raise?: false
      )

      assert :ok = perform_job(PaymentExpiryWorker, %{})

      # :skip 不阻塞整拍；订单保持 pending（吞掉的 UPDATE 未生效），下拍再扫
      assert reload_order(order).status == :pending

      drop_trigger("swallow_expire", "payments_orders")

      assert :ok = perform_job(PaymentExpiryWorker, %{})
      assert reload_order(order).status == :expired
    end
  end

  # #845 钉测：自助取消退款竞态 fail-closed。RETURN NULL 确定性模拟 start_refund
  # claim 未命中（PaymentExpiryWorker CAS 用例同款手法），重读仍未收敛（paid）→
  # 取消必须整体回滚，绝不静默留「已取消但钱未退」半态。
  #
  # R1-#1 机制更正：迁移初期注释称透出 order_already_processed 的原因是
  # 「CaseClauseError 被 Ash 引擎吞掉」——错误。真正原因是 Ash 默认
  # rollback_on_error?: true：commence 内嵌套 action 失败即回滚外层事务，
  # reread_and_reclassify 根本执行不到，cancel 收到的是回滚携带的 claim 错误。
  # R1-#1 修复（rollback_on_error?: false）后重读真正执行：已收敛 → 取消成功
  # （有意行为修复，产品拍板 A），未收敛 → raise 上抛回滚（code 不变）。
  describe "Enrollment 自助取消退款竞态守卫（#845）" do
    test "CAS 未命中且重读未收敛 → 取消回滚：报名 confirmed、订单留 paid、无退款 job" do
      admin = Fixtures.platform_admin("cancel-race-guard-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [@tier],
          starts_at: DateTime.add(DateTime.utc_now(), 9, :day)
        })

      learner = Fixtures.register_user("cancel-race-guard-learner-" <> uniq())

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
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-race-guard"})
        |> Ash.update(tenant: workspace.id, authorize?: false)

      {:ok, _} =
        enrollment
        |> Ash.Changeset.for_update(:settle_paid, %{})
        |> Ash.update(tenant: workspace.id, authorize?: false)

      # 只拦该订单 paid→refunding 的 claim UPDATE：num_rows=0 → 已处理竞态；
      # 重读 status 仍 paid（非 refunding/refunded）→ 收敛失败分支
      inject_trigger(
        "block_self_cancel_claim",
        "payments_orders",
        ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding')},
        raise?: false
      )

      # 未收敛 = 真故障：raise 上抛回滚（after_action 返回 {:error, _} 会提交，
      # raise 是唯一回滚形状）；rollback_on_error?: false（R1-#1）后 reread 真正
      # 执行、未收敛时透传原始错误，错误 code 与迁移前一致
      raised =
        assert_raise Ash.Error.Invalid, fn ->
          enrollment
          |> Ash.Changeset.for_update(:cancel, %{})
          |> Ash.update(tenant: workspace.id, actor: learner)
        end

      assert [%Cgc2046.Errors.BusinessError{code: "order_already_processed"}] = raised.errors

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
      admin = Fixtures.platform_admin("cancel-race-settled-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [@tier],
          starts_at: DateTime.add(DateTime.utc_now(), 9, :day)
        })

      learner = Fixtures.register_user("cancel-race-settled-learner-" <> uniq())

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
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-race-settled"})
        |> Ash.update(tenant: workspace.id, authorize?: false)

      {:ok, _} =
        enrollment
        |> Ash.Changeset.for_update(:settle_paid, %{})
        |> Ash.update(tenant: workspace.id, authorize?: false)

      # 模拟「他路已提交推进」：BEFORE ROW（depth=1）吞掉本侧 claim UPDATE →
      # num_rows=0；AFTER STATEMENT 随即把该行真改为 refunding（内层 UPDATE 经
      # depth>1 分支放行）——重读见 refunding → already_in_progress
      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_race_swallow_fn() RETURNS trigger AS } <>
          ~s{$$ BEGIN IF pg_trigger_depth() = 1 THEN RETURN NULL; ELSE RETURN NEW; END IF; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER race_swallow BEFORE UPDATE ON payments_orders FOR EACH ROW } <>
          ~s{WHEN (OLD.id = '#{order.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding') } <>
          ~s{EXECUTE FUNCTION cgc_race_swallow_fn();}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_race_settle_fn() RETURNS trigger AS } <>
          ~s{$$ BEGIN IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF; UPDATE payments_orders SET status = 'refunding' WHERE id = '#{order.id}' AND status = 'paid'; RETURN NULL; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER race_settle AFTER UPDATE ON payments_orders FOR EACH STATEMENT } <>
          ~s{EXECUTE FUNCTION cgc_race_settle_fn();}
      )

      # 他路已入队 1 笔（竞态收敛的前提语义）
      Cgc2046.Repo.query!(
        ~s{INSERT INTO oban_jobs (state, queue, worker, args, priority, max_attempts, inserted_at, scheduled_at) } <>
          ~s{VALUES ('available', 'payments', 'Cgc2046.Payments.Workers.PaymentRefundWorker', } <>
          ~s{jsonb_build_object('order_id', '#{order.id}'), 0, 5, NOW(), NOW())}
      )

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

  # #845 钉测：批量退款的逐笔隔离。单笔入队失败（渠道窗口的 DB 故障形状）只
  # 跳过该笔，批次其余照退——refund_paid_order 的 reduce 不得中断。
  describe "OfferingCancelRefundWorker 逐笔隔离守卫（#845）" do
    test "单笔入队失败：该笔回滚留 paid 无 job，批次其余照常 refunding + 入队" do
      admin = Fixtures.platform_admin("batch-skip-guard-admin-" <> uniq())
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{
          pricing_enabled: true,
          price_tiers: [@tier]
        })

      paid_enrollments =
        Enum.map(["batch-skip-a", "batch-skip-b"], fn suffix ->
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
      # already_processed → with 短路 → 该笔 transaction 返回 error → log_skip。
      # RETURN NULL 而非 RAISE（RAISE 会断共享连接炸整批，attendance 入队失败
      # 用例同款教训）；PaymentExpiryWorker CAS 用例同款手法。
      inject_trigger(
        "block_one_refund_claim",
        "payments_orders",
        ~s{WHEN (OLD.id = '#{failing.id}' AND OLD.status = 'paid' AND NEW.status = 'refunding')},
        raise?: false
      )

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

      # 存活笔照常进入退款链
      assert reload_order(surviving).status == :refunding

      assert [%{args: %{"order_id" => surviving_id}}] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] in [failing.id, surviving.id]))

      assert surviving_id == surviving.id

      # 失败笔：整体回滚（订单留 paid）、无 job、不阻塞批次
      assert reload_order(failing).status == :paid

      assert [] =
               all_enqueued(worker: PaymentRefundWorker)
               |> Enum.filter(&(&1.args["order_id"] == failing.id))
    end
  end

  # ── 布置 ──

  # paid 落账完成态：order=paid + enrollment=confirmed（免缴/落账守卫共用的
  # 占位确认态布置）
  defp paid_order_setup do
    %{workspace: workspace, enrollment: enrollment, order: order} = base_setup()

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "guard-txn"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      Ash.get!(Enrollment, enrollment.id, authorize?: false)
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    %{
      workspace: workspace,
      enrollment: enrollment,
      order: reload_order(order)
    }
  end

  # 过期扫描命中态：pending 订单且 expire_at 已过点。
  # （唯一活跃单索引：每报名至多一个非终态订单——先 cancel 布置单（终态），
  # 再建第二笔带过期时刻的 pending 单）
  defp expired_order_setup do
    %{workspace: workspace, enrollment: enrollment, order: order} = base_setup()

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:cancel, %{cancel_reason: "guard_recreate"})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native,
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: @tier,
        expire_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    %{workspace: workspace, enrollment: enrollment, order: order}
  end

  defp base_setup do
    admin = Fixtures.platform_admin("failclosed-guard-admin-" <> uniq())
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [@tier]
      })

    learner = Fixtures.register_user("failclosed-guard-learner-" <> uniq())

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

    %{workspace: workspace, enrollment: enrollment, order: order}
  end

  defp to_refunded(order) do
    {:ok, refunding} =
      order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)

    {:ok, _} =
      refunding
      |> Ash.Changeset.for_update(:refund_succeeded, %{})
      |> Ash.update(tenant: order.workspace_id, authorize?: false)
  end

  # 沙箱事务内注入/解除行级触发器（DDL 事务性，测试结束回滚；本文件 async: false
  # 串行——迁移到并行文件会在热表上互等/死锁，见 moduledoc F2）。
  # table 参数化：block_mark_paid/block_expire/swallow_expire 在 payments_orders，
  # block_settle（F-I 报名 CAS 守卫）在 enrollments——两张都是热表，同一纪律。
  defp inject_trigger(name, table, when_clause, opts) do
    timing = Keyword.get(opts, :timing, :update)

    body =
      if Keyword.get(opts, :raise?, true) do
        "BEGIN RAISE EXCEPTION 'test injected db failure'; END;"
      else
        "BEGIN RETURN NULL; END;"
      end

    Cgc2046.Repo.query!(
      ~s{CREATE OR REPLACE FUNCTION cgc_test_#{name}() RETURNS trigger AS } <>
        ~s{$$ #{body} $$ LANGUAGE plpgsql;}
    )

    Cgc2046.Repo.query!(
      ~s{CREATE TRIGGER #{name} BEFORE #{timing} ON #{table} FOR EACH ROW } <>
        ~s{#{when_clause} EXECUTE FUNCTION cgc_test_#{name}();}
    )
  end

  defp drop_trigger(name, table) do
    Cgc2046.Repo.query!("DROP TRIGGER #{name} ON #{table}")
    Cgc2046.Repo.query!("DROP FUNCTION cgc_test_#{name}")
  end

  defp stub_channel_paid(order) do
    Fake.script!(
      fetch_transaction:
        {:ok, %{status: :paid, amount_cents: order.amount_cents, transaction_id: "txn-guard-1"}}
    )
  end

  defp perform_settlement(order) do
    event_id = "evt-" <> order.out_trade_no

    event =
      WebhookEvent
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.read_one!(authorize?: false)
      |> case do
        nil ->
          WebhookEvent
          |> Ash.Changeset.for_create(:create, %{
            provider: :wechat,
            event_id: event_id,
            payload: %{"out_trade_no" => order.out_trade_no}
          })
          |> Ash.create!(authorize?: false)

        existing ->
          existing
      end

    perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event.id})
  end

  defp event_for(order) do
    WebhookEvent
    |> Ash.Query.filter(event_id == ^("evt-" <> order.out_trade_no))
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_order(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
