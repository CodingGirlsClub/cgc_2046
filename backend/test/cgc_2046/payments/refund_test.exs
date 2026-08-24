defmodule Cgc2046.Payments.RefundTest do
  @moduledoc """
  U9：退款 action + 渠道 worker + Event cancelled 批量（R15-R17/R19/R22，F3）。

  - 单笔成功：refunding → refunded + 报名 cancelled + 名额释放 + 双方通知。
  - 渠道拒绝 + retry：refund_failed + 通知；retry_refund 重入后成功。
  - 权限：Owner/Admin ✅ / 普通成员 403 / PlatformAdmin ✅（R19 兜底）。
  - 批量（Event cancelled）：paid 逐笔退款、payment_pending 取消释放、其余跳过、
    逐笔隔离部分失败不阻塞。
  - 退款回调重放：已 refunded 再投递零变化（幂等）。
  - 退款即取消后名额可被他人报名。
  - 查单兜底：回调丢失（受理未终态）→ 重试经查单收敛 refunded。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Enrollment, Event}
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Workers.{OfferingCancelRefundWorker, NotificationWorker, PaymentRefundWorker}

  @tier_id "66666666-6666-6666-6666-666666666666"

  describe "单笔退款链（refund action + PaymentRefundWorker）" do
    test "单笔成功：refunded + 报名 cancelled + 名额释放 + 双方通知", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: 1)

      {:ok, refunding} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      assert refunding.status == :refunding
      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => setup.order.id})

      # 审计留痕（LogAdminAction）
      assert [%{action: :order_refund, target_type: :order}] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == setup.order.id))

      Fake.script!(fetch_transaction: {:ok, refund_txn(paid: true)})

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})

      assert reload_order(setup.order).status == :refunded
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
      assert event_count(setup.event) == 0

      # 双方通知：报名人 + workspace 管理者（R22）
      refund_notifs =
        all_enqueued(worker: NotificationWorker)
        |> Enum.filter(&(&1.args["template_key"] == "refund_succeeded"))

      assert Enum.any?(refund_notifs, &(&1.args["user_id"] == setup.learner.id))
      assert Enum.any?(refund_notifs, &(&1.args["user_id"] == admin.id))
    end

    test "渠道拒绝：refund_failed + 通知；retry_refund 后成功", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: nil)

      {:ok, _} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      Fake.script!(refund: {:error, :channel_refund_failed})

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert reload_order(setup.order).status == :refund_failed

      assert Enum.any?(
               all_enqueued(worker: NotificationWorker),
               &(&1.args["template_key"] == "refund_failed" and
                   &1.args["user_id"] == setup.learner.id)
             )

      # 报名保持 confirmed（失败未取消）
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :confirmed

      # 管理员重试：refund_failed → refunding 重入同一链（R17）
      Fake.reset!()
      Fake.script!(fetch_transaction: {:ok, refund_txn(paid: false)})

      {:ok, _retried} =
        reload_order(setup.order)
        |> Ash.Changeset.for_update(:retry_refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => setup.order.id})

      Fake.script!(
        refund: :ok,
        fetch_transaction: {:ok, refund_txn(paid: true)}
      )

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert reload_order(setup.order).status == :refunded
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
    after
      Fake.reset!()
    end

    test "权限：Owner/Admin ✅ / 普通成员 403 / PlatformAdmin ✅", ctx do
      owner = Fixtures.platform_admin("refund-owner")
      setup = paid_setup(ctx, owner, capacity: nil)

      admin = Fixtures.register_user("refund-ws-admin")
      Fixtures.add_member(setup.workspace, admin, [:admin])

      member = Fixtures.register_user("refund-ws-member")
      Fixtures.add_member(setup.workspace, member, [:member])

      # 普通成员 403
      assert {:error, %Ash.Error.Forbidden{}} =
               setup.order
               |> Ash.Changeset.for_update(:refund, %{})
               |> Ash.update(tenant: setup.workspace.id, actor: member)

      # Workspace Admin ✅
      assert {:ok, %Order{status: :refunding}} =
               setup.order
               |> Ash.Changeset.for_update(:refund, %{})
               |> Ash.update(tenant: setup.workspace.id, actor: admin)

      # PlatformAdmin ✅（R19 退款兜底权）
      {:ok, failed} =
        reload_order(setup.order)
        |> Ash.Changeset.for_update(:mark_refund_failed, %{})
        |> Ash.update(tenant: setup.workspace.id, authorize?: false)

      assert {:ok, %Order{status: :refunding}} =
               failed
               |> Ash.Changeset.for_update(:retry_refund, %{})
               |> Ash.update(tenant: setup.workspace.id, actor: owner)
    end

    test "退款回调重放：已 refunded 再投递零变化", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: 1)

      {:ok, _} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      Fake.script!(fetch_transaction: {:ok, refund_txn(paid: true)})

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})

      assert reload_order(setup.order).status == :refunded
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
      assert event_count(setup.event) == 0

      # 通知恰好一轮（报名人 + 管理者各一条，重放不重复）
      assert [_one, _two] =
               all_enqueued(worker: NotificationWorker)
               |> Enum.filter(&(&1.args["template_key"] == "refund_succeeded"))
               |> Enum.uniq_by(&{&1.args["user_id"], &1.args["identity_uid"]})
    end

    test "退款即取消后名额可被他人报名", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: 1)

      {:ok, _} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      Fake.script!(fetch_transaction: {:ok, refund_txn(paid: true)})

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert event_count(setup.event) == 0

      other = Fixtures.register_user("refund-re_enroll")

      {:ok, re} =
        Enrollment
        |> Ash.Changeset.for_create(:create_enrollment, %{
          event_id: setup.event.id,
          user_id: other.id,
          tier_id: @tier_id
        })
        |> Ash.create(tenant: setup.workspace.id, actor: other)

      assert re.status == :payment_pending
      assert event_count(setup.event) == 1
    end

    test "查单兜底：回调丢失（受理未终态）→ 重试经查单收敛 refunded", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: nil)

      {:ok, _} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      # 渠道受理成功但退款未到账（微信异步窗，回调丢失）
      Fake.script!(
        refund: :ok,
        fetch_transaction: {:ok, refund_txn(paid: false)}
      )

      assert {:error, :refund_pending} =
               perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})

      assert reload_order(setup.order).status == :refunding

      # 重试（Oban 重入）：不重复调渠道退款，查单见 refunded 直接收敛
      Fake.script!(
        refund: {:error, :channel_refund_failed},
        fetch_transaction: {:ok, refund_txn(paid: true)}
      )

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert reload_order(setup.order).status == :refunded
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
    after
      Fake.reset!()
    end

    test "F1 支付宝同步退款：查单仅报支付态也能收敛（TRADE_SUCCESS 归一产物）", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: 1, provider: :alipay_page)

      {:ok, _} =
        setup.order
        |> Ash.Changeset.for_update(:refund, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      # 真实形状（不经 Fake 直喂 :refunded 终态）：alipay.trade.query 的
      # trade_status 无退款终态枚举——退款后查单仍是 TRADE_SUCCESS 归一产物
      # :paid。收敛唯一可能路径 = Alipay.refund 的 {:ok, :completed}（同步语义）。
      Fake.script!(
        fetch_transaction:
          {:ok, %{status: :paid, amount_cents: 19_900, transaction_id: "txn-trade-success"}},
        refund: {:ok, :completed}
      )

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})

      assert reload_order(setup.order).status == :refunded
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
      assert event_count(setup.event) == 0
    after
      Fake.reset!()
    end

    test "F-B 退款收尾断裂自愈：refunded 落库后 cancel 失败 → 重试补取消", ctx do
      admin = Fixtures.platform_admin()
      setup = paid_setup(ctx, admin, capacity: 1)

      # 模拟 finalize 第一步落库后、报名取消前崩溃：订单已 refunded，报名仍
      # confirmed 占位（两事务间窗口）
      {:ok, refunding} =
        setup.order
        |> Ash.Changeset.for_update(:start_refund, %{})
        |> Ash.update(tenant: setup.workspace.id, authorize?: false)

      {:ok, _} =
        refunding
        |> Ash.Changeset.for_update(:refund_succeeded, %{})
        |> Ash.update(tenant: setup.workspace.id, authorize?: false)

      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :confirmed

      # 注入取消失败：容量计数置 0 → release_capacity :capacity_counter_invalid
      set_event_count(setup.event, 0)

      assert {:error, {:cancel_failed, _}} =
               perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})

      # 未被吞错跳过：报名保持占位，等重试收敛（拒绝「钱已退、坑还占」）
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :confirmed

      # 解除注入 → Oban 重试经 :refunded 状态门补取消 + 名额回落
      set_event_count(setup.event, 1)

      assert :ok = perform_job(PaymentRefundWorker, %{"order_id" => setup.order.id})
      assert Ash.get!(Enrollment, setup.enrollment.id, authorize?: false).status == :cancelled
      assert event_count(setup.event) == 0
    end
  end

  describe "Event cancelled 批量（OfferingCancelRefundWorker）" do
    test "paid 逐笔退款、payment_pending 取消释放、其余跳过、逐笔隔离", ctx do
      admin = Fixtures.platform_admin()
      setup = batch_setup(ctx, admin)

      # Event open → cancelled（发 event.ended 信号；测试经 SignalSubscriber.deliver
      # 同码入口投递，与生产 forwarder 一致）
      {:ok, cancelled} =
        setup.event
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      assert cancelled.status == :cancelled

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(OfferingCancelRefundWorker, %{
                 type: "event.ended",
                 data: %{
                   "event_id" => setup.event.id,
                   "idempotency_key" => "event.ended:" <> setup.event.id
                 }
               })

      # paid 两笔：逐笔入退款链
      for order <- setup.paid_orders do
        assert reload_order(order).status == :refunding
      end

      assert_enqueued(
        worker: PaymentRefundWorker,
        args: %{"order_id" => hd(setup.paid_orders).id}
      )

      # payment_pending：cancelled + 订单作废 + 名额释放（含已被处理的一笔不阻塞其余）
      for enrollment <- setup.pending_enrollments do
        assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
      end

      for order <- setup.pending_orders do
        assert reload_order(order).status == :cancelled
      end

      # refunding 单跳过（已在渠道链中，不重复入队）
      assert reload_order(setup.refunding_order).status == :refunding

      # expired 报名 + 免缴 confirmed（无 paid 单）不受影响
      assert Ash.get!(Enrollment, setup.expired_enrollment.id, authorize?: false).status ==
               :expired

      assert Ash.get!(Enrollment, setup.waived_enrollment.id, authorize?: false).status ==
               :confirmed

      # 名额账本：占位 7（paid2 + pending2 + refunding1 + expired1 + waived1）
      # - expired 1 已在布置的 :expire 联动释放 - pending_e1 布置预取消释放 1
      # - 批量本轮：pending_e2 取消释放 1（paid 2 的释放发生在退款 worker 收尾，
      #   订阅方只入队不落终态）= 7 - 3 = 4
      assert event_count(setup.event) == 4

      # U1 回归：批量退款审计行真实落库可查回（target_type :event 曾因枚举缺值
      # 静默写入失败——log 吞错后自上线以来未落一行）
      assert [%{action: :event_cancel_batch_refund, target_type: :event}] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == setup.event.id))

      assert [%{"cancelled_enrollments" => 1, "refunded_orders" => 2}] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == setup.event.id))
               |> Enum.map(& &1.metadata)
    end

    test "批量审计枚举：event/course target_type 与 course 批量 action 通过校验", _ctx do
      id = Ecto.UUID.generate()

      assert {:ok, _} =
               Cgc2046.Accounts.AdminActionLog.log(%{
                 actor_id: nil,
                 action: :course_cancel_batch_refund,
                 target_type: :course,
                 target_id: id
               })

      assert [%{action: :course_cancel_batch_refund, target_type: :course}] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == id))
    end

    test "Course cancelled：paid 逐笔退款 + pending 取消 + 审计行（AE7）", ctx do
      admin = Fixtures.platform_admin()
      setup = course_batch_setup(ctx, admin)

      {:ok, cancelled} =
        setup.course
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      assert cancelled.status == :cancelled

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(OfferingCancelRefundWorker, %{
                 type: "course.ended",
                 data: %{
                   "course_id" => setup.course.id,
                   "idempotency_key" => "course.ended:" <> setup.course.id
                 }
               })

      for order <- setup.paid_orders do
        assert reload_order(order).status == :refunding
      end

      assert_enqueued(
        worker: PaymentRefundWorker,
        args: %{"order_id" => hd(setup.paid_orders).id}
      )

      for enrollment <- setup.pending_enrollments do
        assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :cancelled
      end

      for order <- setup.pending_orders do
        assert reload_order(order).status == :cancelled
      end

      # 审计行：course 批量 action + target_type（U1 枚举 + U2 接线）
      assert [%{action: :course_cancel_batch_refund, target_type: :course}] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == setup.course.id))
    end

    test "Course closed（正常结束）：零订单变化，明确不退", ctx do
      admin = Fixtures.platform_admin()
      setup = course_batch_setup(ctx, admin)

      {:ok, closed} =
        setup.course
        |> Ash.Changeset.for_update(:close, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      assert closed.status == :closed

      assert :ok =
               Cgc2046.Workflows.SignalSubscriber.deliver(OfferingCancelRefundWorker, %{
                 type: "course.ended",
                 data: %{
                   "course_id" => setup.course.id,
                   "idempotency_key" => "course.ended:" <> setup.course.id
                 }
               })

      for order <- setup.paid_orders do
        assert reload_order(order).status == :paid
      end

      for enrollment <- setup.pending_enrollments do
        assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status ==
                 :payment_pending
      end

      assert [] =
               Ash.read!(Cgc2046.Accounts.AdminActionLog, authorize?: false)
               |> Enum.filter(&(&1.target_id == setup.course.id))
    end

    test "信号重投幂等：同一 idempotency_key 二次投递不重复退款", ctx do
      admin = Fixtures.platform_admin()
      setup = course_batch_setup(ctx, admin)

      {:ok, _} =
        setup.course
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: setup.workspace.id, actor: admin)

      signal = %{
        type: "course.ended",
        data: %{
          "course_id" => setup.course.id,
          "idempotency_key" => "course.ended:" <> setup.course.id
        }
      }

      assert :ok = Cgc2046.Workflows.SignalSubscriber.deliver(OfferingCancelRefundWorker, signal)
      assert :ok = Cgc2046.Workflows.SignalSubscriber.deliver(OfferingCancelRefundWorker, signal)

      # 退款 job 恰好两笔（每 paid 订单一个），重投不重复入队
      paid_ids = MapSet.new(setup.paid_orders, & &1.id)

      jobs =
        all_enqueued(worker: PaymentRefundWorker)
        |> Enum.filter(&MapSet.member?(paid_ids, &1.args["order_id"]))

      assert length(jobs) == 2
    end
  end

  # ── 布置 ──

  defp refund_txn(paid: true),
    do: %{status: :refunded, amount_cents: 19_900, transaction_id: "txn-refunded"}

  defp refund_txn(paid: false),
    do: %{status: :pending, amount_cents: 19_900, transaction_id: "txn-open"}

  defp paid_setup(_ctx, admin, opts) do
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        capacity: Keyword.get(opts, :capacity),
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("refund-learner-" <> uniq())

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    # 双方通知收件面（R22）：报名人 + 管理者各挂一个 wechat 身份
    insert_identity(learner.id, :wechat, "refund-learner-" <> uniq())
    insert_identity(admin.id, :wechat, "refund-admin-" <> uniq())

    order =
      create_paid_order(workspace, enrollment,
        provider: Keyword.get(opts, :provider, :wechat_native)
      )

    %{workspace: workspace, event: event, learner: learner, enrollment: enrollment, order: order}
  end

  defp batch_setup(_ctx, admin) do
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        capacity: nil,
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    mk = fn suffix ->
      learner = Fixtures.register_user("batch-" <> suffix <> "-" <> uniq())

      {:ok, enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(:create_enrollment, %{
          event_id: event.id,
          user_id: learner.id,
          tier_id: @tier_id
        })
        |> Ash.create(tenant: workspace.id, actor: learner)

      {learner, enrollment}
    end

    {_, paid_e1} = mk.("paid1")
    {_, paid_e2} = mk.("paid2")
    paid_orders = [create_paid_order(workspace, paid_e1), create_paid_order(workspace, paid_e2)]

    {_, pending_e1} = mk.("pending1")
    {_, pending_e2} = mk.("pending2")

    pending_orders = [
      create_pending_order(workspace, pending_e1),
      create_pending_order(workspace, pending_e2)
    ]

    # 逐笔隔离素材：pending_e1 先被取消（等效单笔已处理/竞态），不阻塞其余
    pending_e1
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update(tenant: workspace.id, actor: nil, authorize?: false)
    |> then(&({:ok, _} = &1))

    # refunding 单（已在渠道链）跳过
    {_, refunding_e} = mk.("refunding")
    refunding_order = create_paid_order(workspace, refunding_e)

    refunding_order =
      refunding_order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)
      |> elem(1)

    # expired 报名（跳过面）
    {_, expired_e} = mk.("expired")
    expired_order = create_pending_order(workspace, expired_e, expire_at: true)

    expired_order
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: workspace.id, authorize?: false)
    |> then(&({:ok, _} = &1))

    # 免缴 confirmed（无 paid 单，占位保留）
    {_, waived_e} = mk.("waived")

    waived_e
    |> Ash.Changeset.for_update(:waive_payment, %{})
    |> Ash.update(tenant: workspace.id, actor: admin)
    |> then(&({:ok, _} = &1))

    %{
      workspace: workspace,
      event: event,
      paid_orders: paid_orders,
      pending_orders: pending_orders,
      pending_enrollments: [pending_e1, pending_e2],
      refunding_order: refunding_order,
      expired_enrollment: expired_e,
      waived_enrollment: waived_e
    }
  end

  # U2 Course 批量布置：与 batch_setup 同构（course_id 关联），取核心矩阵
  # （paid×2 + pending×1）——逐笔逻辑与 Event 共享，接线正确性由本布置证明。
  defp course_batch_setup(_ctx, admin) do
    workspace = Fixtures.create_workspace(admin)

    course =
      EventFixtures.create_course(workspace, admin, %{
        capacity: nil,
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    mk = fn suffix ->
      learner = Fixtures.register_user("cbatch-" <> suffix <> "-" <> uniq())

      {:ok, enrollment} =
        Enrollment
        |> Ash.Changeset.for_create(:create_enrollment, %{
          course_id: course.id,
          user_id: learner.id,
          tier_id: @tier_id
        })
        |> Ash.create(tenant: workspace.id, actor: learner)

      enrollment
    end

    paid = [mk.("paid1"), mk.("paid2")]
    paid_orders = Enum.map(paid, &create_paid_order(workspace, &1))
    pending = mk.("pending1")
    pending_orders = [create_pending_order(workspace, pending)]

    %{
      workspace: workspace,
      course: course,
      paid_orders: paid_orders,
      pending_orders: pending_orders,
      pending_enrollments: [pending]
    }
  end

  defp create_pending_order(workspace, enrollment, opts \\ []) do
    expire_at =
      if opts[:expire_at] do
        DateTime.add(DateTime.utc_now(), -1, :hour)
      else
        DateTime.add(DateTime.utc_now(), 2, :hour)
      end

    {:ok, order} =
      Order
      |> Ash.Changeset.for_create(:create, %{
        enrollment_id: enrollment.id,
        provider: Keyword.get(opts, :provider, :wechat_native),
        out_trade_no: "oto-" <> Ecto.UUID.generate(),
        amount_cents: 19_900,
        tier_snapshot: %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900},
        expire_at: expire_at
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    order
  end

  defp create_paid_order(workspace, enrollment, opts \\ []) do
    order = create_pending_order(workspace, enrollment, opts)

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> uniq()})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    paid
  end

  defp event_count(event) do
    Ash.get!(Event, event.id, authorize?: false).confirmed_count
  end

  defp set_event_count(event, count) do
    {:ok, _} =
      Cgc2046.Repo.query("UPDATE events SET confirmed_count = $1 WHERE id = $2", [
        count,
        Ecto.UUID.dump!(event.id)
      ])

    :ok
  end

  defp reload_order(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp insert_identity(user_id, provider, uid) do
    Cgc2046.Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp uniq, do: String.slice(Ecto.UUID.generate(), 0, 8)
end
