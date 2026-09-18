defmodule Cgc2046.Payments.OrderTest do
  @moduledoc """
  支付闭环 U1：Order 状态机骨架 + 库级不变量（R11 唯一活跃订单部分索引 /
  R21 WebhookEvent 幂等去重）；event-deposit U7：forfeited 终态与 forfeit CAS、
  forfeited 统计桶、重复支付回调对 forfeited 单的迟到裁决；event-deposit U2：
  押金单金额源分派（KTD1）——下单/换渠道取押金快照而非定价档位，落账链零改动。

  全部动作以 authorize?: false 走内部路径（worker/域服务语义）；面向用户的
  policy 随 U5/U9 暴露时细化。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  import ExUnit.CaptureLog

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{Order, WebhookEvent}
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.Workers.{PaymentRefundWorker, PaymentSettlementWorker}
  alias Cgc2046.Reconciliation.Finding

  # #405/#U2 布置共用的付费档位 id。
  @idempotent_tier_id "44444444-4444-4444-4444-444444444444"

  describe "状态机：合法迁移" do
    test "mark_paid：pending → paid，落 transaction_id" do
      order = order_fixture()

      assert {:ok, paid} = transition(order, :mark_paid, %{transaction_id: "wx-txn-001"})
      assert paid.status == :paid
      assert paid.transaction_id == "wx-txn-001"
    end

    test "cancel：pending → cancelled，落 cancel_reason" do
      order = order_fixture()

      assert {:ok, cancelled} =
               transition(order, :cancel, %{cancel_reason: "用户切换支付方式"})

      assert cancelled.status == :cancelled
      assert cancelled.cancel_reason == "用户切换支付方式"
    end

    test "expire：pending → expired" do
      order = order_fixture()

      assert {:ok, expired} = transition(order, :expire)
      assert expired.status == :expired
    end

    test "start_refund + refund_succeeded：paid → refunding → refunded，落 refunded_at" do
      order = paid_order()

      assert {:ok, refunding} = transition(order, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
      refute is_nil(refunded.refunded_at)
    end

    test "迟到支付自动退款路径（ADR-0007）：expired → refunding → refunded" do
      order = expired_order()

      assert {:ok, refunding} = transition(order, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
      refute is_nil(refunded.refunded_at)
    end

    test "迟到支付自动退款路径（e2e #1）：cancelled → refunding → refunded" do
      # 免缴/报名取消作废的单，本地作废不关渠道单——QR 仍可被支付，
      # 迟到收款必须能进退款链（AE2 语义）
      {:ok, cancelled} = transition(order_fixture(), :cancel, %{cancel_reason: "waived"})

      assert {:ok, refunding} = transition(cancelled, :start_refund)
      assert refunding.status == :refunding

      assert {:ok, refunded} = transition(refunding, :refund_succeeded)
      assert refunded.status == :refunded
    end

    test "退款失败重试环：refunding → refund_failed →（retry_refund）refunding" do
      order = refund_failed_order()

      assert {:ok, retrying} = transition(order, :retry_refund)
      assert retrying.status == :refunding

      assert {:ok, refunded} = transition(retrying, :refund_succeeded)
      assert refunded.status == :refunded
    end

    test "U7：forfeit——paid → forfeited（no-show 结算终态）" do
      order = paid_deposit_order()

      assert {:ok, forfeited} = transition(order, :forfeit)
      assert forfeited.status == :forfeited
      assert reload(order).status == :forfeited
    end
  end

  describe "状态机：非法迁移（DB CAS 拒绝，状态不变）" do
    test "pending → refunded（refund_succeeded 直跳）拒绝" do
      order = order_fixture()

      assert {:error, error} = transition(order, :refund_succeeded)
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :pending
    end

    test "paid → cancelled 拒绝（已支付必须走退款）" do
      order = paid_order()

      assert {:error, error} = transition(order, :cancel, %{cancel_reason: "batch void"})
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :paid
    end

    test "refund_failed → refunded（refund_succeeded 直跳）拒绝" do
      order = refund_failed_order()

      assert {:error, _} = transition(order, :refund_succeeded)
      assert reload(order).status == :refund_failed
    end

    test "expired → cancelled 拒绝（过期单只可进退款或另建新单）" do
      order = expired_order()

      assert {:error, _} = transition(order, :cancel, %{cancel_reason: "batch void"})
      assert reload(order).status == :expired
    end

    test "refunded 终态拒绝一切后续动作" do
      refunded = refunded_order()

      assert {:error, _} = transition(refunded, :mark_paid, %{transaction_id: "wx-txn-again"})
      assert {:error, _} = transition(refunded, :cancel, %{cancel_reason: "again"})
      assert {:error, _} = transition(refunded, :expire)
      assert {:error, _} = transition(refunded, :start_refund)
      assert {:error, _} = transition(refunded, :refund_succeeded)
      assert {:error, _} = transition(refunded, :retry_refund)

      assert reload(refunded).status == :refunded
    end

    test "cancelled 终态拒绝支付/过期动作（start_refund 除外——迟到收款退款路径）" do
      {:ok, cancelled} = transition(order_fixture(), :cancel, %{cancel_reason: "provider switch"})

      assert {:error, _} = transition(cancelled, :mark_paid, %{transaction_id: "wx-txn-again"})
      assert {:error, _} = transition(cancelled, :expire)

      assert reload(cancelled).status == :cancelled
    end
  end

  describe "R11：同一 enrollment 至多一笔非终态订单（部分唯一索引）" do
    test "并存两笔 pending 被拒绝，首笔不受影响" do
      enrollment = enrollment_fixture()
      assert {:ok, _first} = create_order(enrollment)

      assert {:error, error} = create_order(enrollment)
      assert unique_violation?(error, :enrollment_id)
      assert order_count(enrollment.id) == 1
    end

    test "cancelled 终态放行新订单（部分索引边界：索引只锁非终态窗口）" do
      enrollment = enrollment_fixture()
      {:ok, first} = create_order(enrollment)
      assert {:ok, _cancelled} = transition(first, :cancel, %{cancel_reason: "provider switch"})

      assert {:ok, second} = create_order(enrollment)
      assert second.status == :pending
      assert order_count(enrollment.id) == 2
    end

    test "expired 单进入 refunding 与既有新 pending 互斥（索引同时守卫 CAS 迁移路径）" do
      enrollment = enrollment_fixture()
      {:ok, old} = create_order(enrollment)
      assert {:ok, expired} = transition(old, :expire)

      # expired 不在索引窗口内 → 允许另建新单
      assert {:ok, _fresh} = create_order(enrollment)

      # 旧单此时进退款会让同一 enrollment 出现两笔非终态 → 唯一索引拒绝
      assert {:error, _} = transition(expired, :start_refund)
      assert reload(expired).status == :expired
    end
  end

  describe "#405：create_for_enrollment 幂等下单（重进支付页废旧开新）" do
    test "重复下单不再撞单：旧 pending 置 cancelled(reenter_refresh)、新单携新凭据" do
      {enrollment, learner} = payment_pending_enrollment("idem-reenter")

      assert {:ok, first} = checkout(enrollment, learner)
      assert {:ok, second} = checkout(enrollment, learner)

      # 废旧开新：新订单新 id 新单号；旧单 cancelled 留审计痕，终态不再占索引
      assert second.id != first.id
      assert second.out_trade_no != first.out_trade_no
      assert reload(first).status == :cancelled
      assert reload(first).cancel_reason == "reenter_refresh"
      assert order_count(enrollment.id) == 2

      # 凭据随每次下单重出且对应当次新单号（Fake 回显 out_trade_no）
      second_no = second.out_trade_no
      assert %{"out_trade_no" => ^second_no} = second.__metadata__[:credential]
    end

    test "旧单已 cancelled 终态后下单开新单（与既有 R11 行为一致）" do
      {enrollment, learner} = payment_pending_enrollment("idem-after-cancel")

      assert {:ok, first} = checkout(enrollment, learner)
      assert {:ok, _cancelled} = transition(first, :cancel, %{cancel_reason: "user_cancelled"})

      assert {:ok, second} = checkout(enrollment, learner)
      assert second.id != first.id
      assert order_count(enrollment.id) == 2
    end
  end

  describe "U2：押金单金额源与下单分派（R4/KTD1）" do
    test "押金 ¥69 场 payment_pending 报名下单 → deposit 单金额取押金快照 + 凭据" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-create")

      # 报名提交即物化押金快照（KTD1 金额源）
      assert enrollment.submission_payload["deposit_amount_cents"] == 6900

      assert {:ok, order} = checkout(enrollment, learner)

      assert order.order_kind == :deposit
      assert order.amount_cents == 6900
      assert order.tier_snapshot == %{"name" => "押金", "amount_cents" => 6900}
      # 管理面 tier_name 计算字段读同一快照（零改动）
      assert Ash.load!(order, :tier_name, authorize?: false).tier_name == "押金"

      # 渠道凭据随本次单号回出（Fake 回显 out_trade_no）
      assert %{"out_trade_no" => out_trade_no} = order.__metadata__[:credential]
      assert out_trade_no == order.out_trade_no
    end

    test "重复下单（重进支付页）：旧押金单作废、新单唯一，金额仍取快照" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-idem")

      assert {:ok, first} = checkout(enrollment, learner)
      assert {:ok, second} = checkout(enrollment, learner)

      assert second.id != first.id
      assert second.order_kind == :deposit
      assert second.amount_cents == 6900
      assert reload(first).status == :cancelled
      assert reload(first).cancel_reason == "reenter_refresh"
      assert order_count(enrollment.id) == 2
    end

    test "押金单换渠道：金额与押金形状快照不变（取原单快照，不重新读 Event）" do
      %{enrollment: enrollment, learner: learner, workspace: workspace} =
        deposit_payment_pending_enrollment("u2-replace")

      assert {:ok, first} = checkout(enrollment, learner)

      assert {:ok, second} =
               Order
               |> Ash.Changeset.for_create(:replace_provider, %{
                 order_id: first.id,
                 provider: :alipay_page
               })
               |> Ash.create(tenant: workspace.id, actor: learner)

      assert second.id != first.id
      assert second.order_kind == :deposit
      assert second.amount_cents == 6900
      assert second.tier_snapshot == %{"name" => "押金", "amount_cents" => 6900}
      assert reload(first).status == :cancelled
      assert reload(first).cancel_reason == "provider_switch"
    end

    test "Event 事后关押金：换渠道仍按原单口径（deposit 标签 + 押金金额），不按现状重算" do
      %{
        enrollment: enrollment,
        learner: learner,
        event: event,
        workspace: workspace,
        admin: admin
      } =
        deposit_payment_pending_enrollment("u2-replace-flip")

      assert {:ok, first} = checkout(enrollment, learner)

      # Owner 事后改押金金额（押金仍开）：在途单按原单快照口径换渠道，
      # 不按 Event 现状重算
      assert {:ok, flipped} =
               event
               |> Ash.Changeset.for_update(:update, %{deposit_amount_cents: 9900})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert flipped.deposit_amount_cents == 9900

      assert {:ok, second} =
               Order
               |> Ash.Changeset.for_create(:replace_provider, %{
                 order_id: first.id,
                 provider: :alipay_page
               })
               |> Ash.create(tenant: workspace.id, actor: learner)

      # 口径继承原单：kind 与金额同源，不产出「新押金金额 + 旧单标签」的自相矛盾单
      assert second.order_kind == :deposit
      assert second.amount_cents == 6900
      assert second.tier_snapshot == %{"name" => "押金", "amount_cents" => 6900}
    end

    test "Event 事后关押金：在途押金报名走免缴转 confirmed、押金单作废（KTD1/KTD3 计费槽关闭）" do
      %{
        enrollment: enrollment,
        learner: learner,
        event: event,
        workspace: workspace,
        admin: admin
      } =
        deposit_payment_pending_enrollment("u2-replace-waive")

      assert {:ok, first} = checkout(enrollment, learner)

      assert {:ok, flipped} =
               event
               |> Ash.Changeset.for_update(:update, %{deposit_enabled: false})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert flipped.deposit_enabled == false

      # 关押金 = 计费槽关闭：待付报名免缴转 confirmed、在途单作废（不再等过期）
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert reload(first).status == :cancelled
      assert reload(first).cancel_reason == "waived"

      # 该报名已 confirmed 且无在途单：再下单被入口门禁拒绝（不产生第二笔收款）
      confirmed = Ash.get!(Enrollment, enrollment.id, authorize?: false)
      assert {:error, _} = checkout(confirmed, learner)
    end

    test "押金单 Fake 回调落账：订单 paid + 报名 confirmed + payment_succeeded 入队" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-settle")

      # 通知收件人零身份 = 零入队（Fanout :skipped）——布置报名者微信身份
      insert_identity(learner.id, :wechat, "u2-settle-openid")

      assert {:ok, order} = checkout(enrollment, learner)
      assert :ok = settle_order(order)

      assert reload(order).status == :paid

      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed

      assert_enqueued(
        worker: Cgc2046.Notifications.NotificationWorker,
        args: %{"user_id" => enrollment.user_id, "template_key" => "payment_succeeded"}
      )
    after
      Fake.reset!()
    end

    test "渠道金额 ≠ 押金（R20 回归）：不落账 + amount_mismatch Finding" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-mismatch")

      assert {:ok, order} = checkout(enrollment, learner)
      assert :ok = settle_order(order, amount_cents: 6800)

      assert reload(order).status == :pending
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :payment_pending

      assert [%{rule: :payment_amount_mismatch, entity_id: entity_id}] =
               Ash.read!(Finding, authorize?: false)

      assert entity_id == order.id
    after
      Fake.reset!()
    end

    test "押金单 expired 后迟到支付回调 → 自动 start_refund 入队（回归迟到裁决）" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-late")

      assert {:ok, order} = checkout(enrollment, learner)

      # 超时扫描：订单 expired 与报名 expired 同事务联动（do_expire）
      assert {:ok, _expired} = transition(order, :expire)
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :expired

      assert :ok = settle_order(order)

      assert reload(order).status == :refunding
      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})
    after
      Fake.reset!()
    end

    test "定价场下单仍走档位解析（分派不误伤定价单）" do
      {enrollment, learner} = payment_pending_enrollment("u2-priced")

      assert {:ok, order} = checkout(enrollment, learner)

      assert order.order_kind == :enrollment
      assert order.amount_cents == 9900
      assert order.tier_snapshot["id"] == @idempotent_tier_id
      assert order.tier_snapshot["name"] == "早鸟"
    end

    test "request 押金场审批通过 → 快照随 payment_pending 落库，下单金额 = 押金" do
      admin = Fixtures.platform_admin("payments-deposit-request-admin")
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(
          workspace,
          admin,
          deposit_attrs(%{enrollment_policy: :request})
        )

      learner = Fixtures.register_user("payments-deposit-request-learner")

      assert {:ok, pending} = create_enrollment(event, learner)
      assert pending.status == :pending

      assert {:ok, approved} =
               pending
               |> Ash.Changeset.for_update(:confirm_enrollment, %{})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert approved.status == :payment_pending
      assert approved.submission_payload["deposit_amount_cents"] == 6900

      assert {:ok, order} = checkout(approved, learner)
      assert order.order_kind == :deposit
      assert order.amount_cents == 6900
    end

    test "报名后 Owner 改押金 69→99：存量 payment_pending 报名按 69（快照），新报名按 99" do
      %{
        enrollment: enrollment,
        learner: learner,
        event: event,
        workspace: workspace,
        admin: admin
      } = deposit_payment_pending_enrollment("u2-reprice")

      assert {:ok, updated} =
               event
               |> Ash.Changeset.for_update(:update, %{deposit_amount_cents: 9900})
               |> Ash.update(tenant: workspace.id, actor: admin)

      assert updated.deposit_amount_cents == 9900

      # 存量报名：承诺金额以报名提交时为准（改价不追溯）
      assert {:ok, existing_order} = checkout(enrollment, learner)
      assert existing_order.amount_cents == 6900

      # 新报名拿新价（新快照）
      fresh_learner = Fixtures.register_user("payments-deposit-learner-u2-reprice-new")
      assert {:ok, fresh} = create_enrollment(event, fresh_learner)
      assert fresh.status == :payment_pending
      assert fresh.submission_payload["deposit_amount_cents"] == 9900

      assert {:ok, fresh_order} = checkout(fresh, fresh_learner)
      assert fresh_order.amount_cents == 9900
    end

    test "存量报名无押金快照（U1→U2 窗口行）→ fail-closed 拒单且零订单残留" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("u2-nosnapshot")

      # 布置：抹掉押金快照——U1 落地（押金场进 payment_pending）到 U2 落地
      # （下单链读快照）之间产生的报名正是这种形状，域内当前无路径可产出。
      Repo.query!(
        "UPDATE enrollments SET submission_payload = submission_payload - 'deposit_amount_cents' WHERE id = $1",
        [Repo.uuid!(enrollment.id)]
      )

      # 无承诺金额可依据 → 拒单，绝不以 nil/零金额调渠道
      assert {:error, error} = checkout(enrollment, learner)
      assert Exception.message(error) =~ "deposit amount snapshot is missing"
      assert order_count(enrollment.id) == 0
    end
  end

  describe "#687：定价单档位金额 fail-closed（脏金额绝不物化订单/调渠道）" do
    for {label, dirty} <- [{"0 元", 0}, {"负数", -100}, {"非整数分", 0.4}] do
      @tag dirty: dirty
      test "脏档位金额（#{label}）下单 → order_tier_amount_invalid，零物化（#687）" do
        dirty = @tag[:dirty]
        admin = Fixtures.platform_admin("payments-dirty-tier-admin")
        workspace = Fixtures.create_workspace(admin)

        event =
          EventFixtures.create_event(workspace, admin, %{
            pricing_enabled: true,
            price_tiers: [
              %{"id" => @idempotent_tier_id, "name" => "早鸟", "amount_cents" => 9900}
            ]
          })

        learner = Fixtures.register_user("payments-dirty-tier-learner")

        {:ok, enrollment} =
          Enrollment
          |> Ash.Changeset.for_create(:create_enrollment, %{
            event_id: event.id,
            user_id: learner.id,
            tier_id: @idempotent_tier_id
          })
          |> Ash.create(tenant: workspace.id, actor: learner)

        assert enrollment.status == :payment_pending

        # 布置而非被测对象：域校验（PriceTiersValidation ≥1 分）挡住脏档，
        # 只有裸 SQL 能造出存量脏行（#627 F5 同款布置）；jsonb 参数直接传
        # Elixir 结构（postgrex 经 Jason 编码；预编码字符串会被再包一层
        # JSON 引号存成 string scalar）
        Cgc2046.Repo.query!(
          "UPDATE events SET price_tiers = $2 WHERE id = $1",
          [
            Ecto.UUID.dump!(event.id),
            [%{"id" => @idempotent_tier_id, "name" => "早鸟", "amount_cents" => dirty}]
          ]
        )

        # 下单 fail-closed（与押金单 deposit_tier 的 order_deposit_amount_missing
        # 同款红线）：渠道调用在事务内，拒绝即回滚——无凭据无订单
        assert {:error, %Ash.Error.Invalid{errors: [error]}} = checkout(enrollment, learner)
        assert error.code == "order_tier_amount_invalid"
        assert Exception.message(error) =~ "invalid amount"
        assert order_count(enrollment.id) == 0
      end
    end
  end

  describe "R21：WebhookEvent (provider, event_id) 幂等去重" do
    test "重复 (provider, event_id) 插入被拒；不同 provider 同 event_id 可并存" do
      assert {:ok, _} = create_webhook_event(:wechat, "evt-dup-1")

      assert {:error, error} = create_webhook_event(:wechat, "evt-dup-1")
      assert unique_violation?(error)

      assert {:ok, _} = create_webhook_event(:alipay, "evt-dup-1")
      assert webhook_event_count() == 2
    end
  end

  describe "U7：forfeited 终态与 forfeit CAS（R9/KTD7）" do
    test "重复 forfeit 幂等：第二次 num_rows=0 → already_processed，状态不变" do
      order = paid_deposit_order()

      assert {:ok, forfeited} = transition(order, :forfeit)
      assert forfeited.status == :forfeited

      assert {:error, error} = transition(forfeited, :forfeit)
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :forfeited
    end

    test "pending / refunding / refunded / cancelled / expired 押金单 → forfeit 一律拒绝" do
      # 全部建在押金单上：拒绝理由必须来自「状态不是 paid」，不是「不是押金单」
      pending = deposit_order()
      assert {:error, _} = transition(pending, :forfeit)
      assert reload(pending).status == :pending

      refunding =
        pending
        |> transition!(:mark_paid, %{transaction_id: "wx-txn-rf"})
        |> transition!(:start_refund)

      assert {:error, _} = transition(refunding, :forfeit)
      assert reload(refunding).status == :refunding

      refunded = transition!(refunding, :refund_succeeded)
      assert {:error, _} = transition(refunded, :forfeit)
      assert reload(refunded).status == :refunded

      # 各分支用独立订单：transition 落库，复用同一 struct 会让后续 CAS 落空
      cancelled_order = deposit_order()
      {:ok, cancelled} = transition(cancelled_order, :cancel, %{cancel_reason: "batch void"})
      assert {:error, _} = transition(cancelled, :forfeit)
      assert reload(cancelled_order).status == :cancelled

      expired_order_row = transition!(deposit_order(), :expire)
      assert {:error, _} = transition(expired_order_row, :forfeit)
      assert reload(expired_order_row).status == :expired
    end

    test "非押金单（普通报名单）paid 态 → forfeit 拒绝（CWE-863：内部动作不误没收）" do
      enrollment = enrollment_fixture()
      {:ok, order} = create_order(enrollment)
      paid = transition!(order, :mark_paid, %{transaction_id: "wx-txn-nondeposit"})

      assert {:error, error} = transition(paid, :forfeit)
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :paid
    end

    test "forfeit 后同一 confirmed 押金报名 createOrder → order_not_payment_pending" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("forfeit-reenter")

      {:ok, order} = checkout(enrollment, learner)
      # 押金单落账走 PaymentSettlementWorker（mark_paid 不内联转报名）：
      # 结算后报名才 confirmed——本用例考察的正是 confirmed 报名 + forfeited 单
      settle_order(order)
      assert Ash.get!(Enrollment, enrollment.id, authorize?: false).status == :confirmed
      assert reload(order).status == :paid

      assert {:ok, _forfeited} = transition(reload(order), :forfeit)

      # confirmed 报名再下单：入口门禁拒绝（索引槽位已释放，但 confirmed 无收款面）
      assert {:error, error} = checkout(enrollment, actor_fixture(enrollment))
      assert Exception.message(error) =~ "not awaiting payment"

      # 索引槽位释放的旁证：绕过门禁直接 create 不再撞 unique_active_order
      assert {:ok, second} = create_order(enrollment)
      assert second.id != order.id
      assert order_count(enrollment.id) == 2
    end

    test "workspace_payment_stats 返回 forfeited 桶（AE7 对账口径）" do
      %{enrollment: enrollment, learner: learner} =
        deposit_payment_pending_enrollment("forfeit-stats")

      {:ok, order} = checkout(enrollment, learner)
      paid = transition!(order, :mark_paid, %{transaction_id: "wx-txn-stats"})
      assert {:ok, _} = transition(paid, :forfeit)

      assert {:ok, stats} =
               Order
               |> Ash.ActionInput.for_action(:workspace_payment_stats, %{
                 workspace_id: enrollment.workspace_id
               })
               |> Ash.run_action(tenant: enrollment.workspace_id, authorize?: false)

      assert stats.forfeited_cents == 6900
      assert stats.collected_cents == 0
      assert stats.refunded_cents == 0
      assert stats.pending_cents == 0
      assert stats.refund_failed_cents == 0
    end

    test "forfeited 单 start_refund → 拒绝（终态，不退）" do
      order = paid_deposit_order()
      assert {:ok, forfeited} = transition(order, :forfeit)

      assert {:error, error} = transition(forfeited, :start_refund)
      assert Exception.message(error) =~ "already been processed"
      assert reload(order).status == :forfeited
    end

    test "重复支付回调命中 forfeited 单 → 落账 worker 记 info、mark_processed、无 error 日志" do
      order = paid_deposit_order()
      assert {:ok, _} = transition(order, :forfeit)

      Fake.script!(
        fetch_transaction:
          {:ok,
           %{
             status: :paid,
             amount_cents: order.amount_cents,
             transaction_id: "txn-forfeit-dup"
           }}
      )

      event =
        WebhookEvent
        |> Ash.Changeset.for_create(:create, %{
          provider: :wechat,
          event_id: "evt-" <> order.out_trade_no,
          payload: %{"out_trade_no" => order.out_trade_no}
        })
        |> Ash.create!(authorize?: false)

      assert :ok =
               perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event.id})

      # 迟到裁决降 info（forfeited 分支），全链无 error 日志
      refute capture_log(fn ->
               perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event.id})
             end) =~ "[error]"

      assert Ash.get!(WebhookEvent, event.id, authorize?: false).status == :processed
      assert reload(order).status == :forfeited
    after
      Fake.reset!()
    end
  end

  # ── 布置与断言帮手 ─────────────────────────────────────────────────────────

  defp enrollment_fixture do
    admin = Fixtures.platform_admin("payments-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    learner = Fixtures.register_user("payments-learner")

    {:ok, enrollment} = create_enrollment(event, learner)
    enrollment
  end

  defp create_enrollment(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create(tenant: event.workspace_id, actor: user)
  end

  # 按报名 user_id 构造最小 actor 结构：本测试只断言入口门禁拒绝
  # （order_not_payment_pending），actor 仅经 enrollee_only 的 .id 比对参与判定。
  defp actor_fixture(enrollment), do: %{id: enrollment.user_id}

  # #405 幂等测试布置：付费活动 + 档位 → 报名落 payment_pending；checkout 走
  # create_for_enrollment 全链路（本人 actor + Fake 渠道）。U2 押金/定价分派
  # 回归同用此档位。
  defp payment_pending_enrollment(tag) do
    admin = Fixtures.platform_admin("payments-idem-admin-#{tag}")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [
          %{"id" => @idempotent_tier_id, "name" => "早鸟", "amount_cents" => 9900}
        ]
      })

    learner = Fixtures.register_user("payments-idem-learner-#{tag}")

    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        event_id: event.id,
        user_id: learner.id,
        tier_id: @idempotent_tier_id
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    assert enrollment.status == :payment_pending
    {enrollment, learner}
  end

  # native 渠道无 openid 前置校验（jsapi 需真实微信 openid，测试用户没有）
  defp checkout(enrollment, actor) do
    Order
    |> Ash.Changeset.for_create(:create_for_enrollment, %{
      enrollment_id: enrollment.id,
      provider: :wechat_native
    })
    |> Ash.create(tenant: enrollment.workspace_id, actor: actor)
  end

  # U2 押金布置：押金场（ends_at 非空是 U3 校验要求，也是 no-show 结算锚点）→
  # 报名落 payment_pending 且 submission_payload 已物化押金快照。
  defp deposit_attrs(extra \\ %{}) do
    Map.merge(
      %{
        deposit_enabled: true,
        deposit_amount_cents: 6900,
        ends_at: EventFixtures.days_from_now(8)
      },
      extra
    )
  end

  defp deposit_payment_pending_enrollment(tag) do
    admin = Fixtures.platform_admin("payments-deposit-admin-#{tag}")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, deposit_attrs())
    learner = Fixtures.register_user("payments-deposit-learner-#{tag}")

    {:ok, enrollment} = create_enrollment(event, learner)
    assert enrollment.status == :payment_pending

    %{admin: admin, workspace: workspace, event: event, learner: learner, enrollment: enrollment}
  end

  # 落账链布置：渠道回查付讫（金额默认等于订单金额）+ webhook 事件 → 跑落账
  # worker（渠道调用走 Fake，生产 adapter 不被测试触碰）。
  defp settle_order(order, overrides \\ []) do
    Fake.script!(
      fetch_transaction:
        {:ok,
         %{
           status: :paid,
           amount_cents: Keyword.get(overrides, :amount_cents, order.amount_cents),
           transaction_id: "txn-" <> order.out_trade_no
         }}
    )

    event =
      WebhookEvent
      |> Ash.Changeset.for_create(:create, %{
        provider: :wechat,
        event_id: "evt-" <> order.out_trade_no,
        payload: %{"out_trade_no" => order.out_trade_no}
      })
      |> Ash.create!(authorize?: false)

    perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event.id})
  end

  # 布置报名者平台身份（通知收件人解析用；Fanout 零身份 → 零入队）。
  defp insert_identity(user_id, provider, uid) do
    Repo.query!(
      """
      INSERT INTO user_identities (id, provider, uid, user_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, NOW(), NOW())
      """,
      [to_string(provider), uid, Ecto.UUID.dump!(user_id)]
    )
  end

  defp order_fixture do
    {:ok, order} = enrollment_fixture() |> create_order()
    order
  end

  defp create_order(enrollment, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          enrollment_id: enrollment.id,
          provider: :wechat_jsapi,
          out_trade_no: "CGC" <> String.replace(Ecto.UUID.generate(), "-", ""),
          amount_cents: 19_900,
          expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
        },
        attrs
      )

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(tenant: enrollment.workspace_id, authorize?: false)
  end

  defp paid_order do
    transition!(order_fixture(), :mark_paid, %{transaction_id: "wx-txn-fixture"})
  end

  # forfeit 仅对押金单开放（KTD7）：no-show 结算对象是押金单，普通报名单
  # 由退款链处置。U7 的状态机用例都建在押金单上。
  # 押金单（pending）：U7 状态矩阵的基线（forfeit 只对押金单开放）
  defp deposit_order do
    %{enrollment: enrollment, learner: learner} =
      deposit_payment_pending_enrollment("deposit-order-#{System.unique_integer([:positive])}")

    {:ok, order} = checkout(enrollment, learner)
    order
  end

  defp paid_deposit_order do
    %{enrollment: enrollment, learner: learner} =
      deposit_payment_pending_enrollment("paid-deposit-#{System.unique_integer([:positive])}")

    {:ok, order} = checkout(enrollment, learner)
    transition!(order, :mark_paid, %{transaction_id: "wx-txn-deposit"})
  end

  defp expired_order, do: transition!(order_fixture(), :expire)

  defp refund_failed_order do
    order_fixture()
    |> transition!(:mark_paid, %{transaction_id: "wx-txn-fixture"})
    |> transition!(:start_refund)
    |> transition!(:mark_refund_failed)
  end

  defp refunded_order do
    order_fixture()
    |> transition!(:mark_paid, %{transaction_id: "wx-txn-fixture"})
    |> transition!(:start_refund)
    |> transition!(:refund_succeeded)
  end

  defp transition(order, action, args \\ %{}) do
    order
    |> Ash.Changeset.for_update(action, args)
    |> Ash.update(tenant: order.workspace_id, authorize?: false)
  end

  defp transition!(order, action, args \\ %{}) do
    {:ok, updated} = transition(order, action, args)
    updated
  end

  defp create_webhook_event(provider, event_id) do
    WebhookEvent
    |> Ash.Changeset.for_create(:create, %{
      provider: provider,
      event_id: event_id,
      payload: %{"raw" => "callback payload"}
    })
    |> Ash.create(authorize?: false)
  end

  defp reload(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp order_count(enrollment_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM payments_orders WHERE enrollment_id = $1", [
        Repo.uuid!(enrollment_id)
      ])

    count
  end

  defp webhook_event_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM payments_webhook_events", [])
    count
  end

  # ash_postgres 把 PG unique violation 映射为带 constraint_type: :unique 的
  # Ash 错误（单列 identity → InvalidAttribute{field: ...}；复合 identity 走
  # 其它形状，故 field 可选）。
  defp unique_violation?(%Ash.Error.Invalid{errors: errors}, field \\ nil) do
    Enum.any?(errors, fn
      %{field: f, private_vars: vars} when field in [nil, f] ->
        Keyword.get(vars || [], :constraint_type) == :unique

      %{private_vars: vars} when is_nil(field) ->
        Keyword.get(vars || [], :constraint_type) == :unique

      _ ->
        false
    end)
  end
end
