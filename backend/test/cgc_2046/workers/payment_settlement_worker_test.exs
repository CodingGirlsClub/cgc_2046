defmodule Cgc2046.Workers.PaymentSettlementWorkerTest do
  @moduledoc """
  U7：回调落账唯一路径（KTD12/R7/R9/R20-R22）。

  - 正常落账：order paid + enrollment confirmed + transaction_id + order.paid 信号 +
    支付成功通知 + webhook_event processed。
  - 重放（幂等，R21 端到端）：二次投递业务状态恰好一次变化。
  - 金额不符（R20）：不落账 + Finding（规⑦ 前置兜底）+ 告警。
  - 回查未支付：无状态变化（等下个回调/对账）。
  - 迟到扣款（AE2）：expired 订单 → refunding + refund job 入队，报名保持 expired。
  - 免缴竞态（AE3 免缴先落）：已 confirmed → paid 落账 + 自动退款链。
  """

  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{Order, WebhookEvent}
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Workers.{PaymentRefundWorker, PaymentSettlementWorker, SignalPublishWorker}

  @tier_id "44444444-4444-4444-4444-444444444444"

  describe "perform/1 落账" do
    test "正常落账：paid + confirmed + 信号 + 通知 + event processed", ctx do
      order = pending_order(ctx)
      stub_channel_paid(order)

      assert :ok = perform_settlement(order)

      reloaded = reload_order(order)
      assert reloaded.status == :paid
      assert reloaded.transaction_id == "txn-fake-1"

      enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
      assert enrollment.status == :confirmed

      # order.paid 信号（SignalEmitter 事务内 outbox）
      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{
          "signal_type" => "order.paid",
          "data" => %{"order_id" => order.id, "idempotency_key" => "order.paid:" <> order.id}
        }
      )

      # 支付成功通知（报名者，R22；模板接线 U10 定稿）
      assert_enqueued(
        worker: Cgc2046.Workers.NotificationWorker,
        args: %{"user_id" => enrollment.user_id, "template_key" => "payment_succeeded"}
      )

      assert event_for(order).status == :processed
    end

    test "重放两次投递：业务状态只变一次（R21 端到端）", ctx do
      order = pending_order(ctx)
      stub_channel_paid(order)

      assert :ok = perform_settlement(order)
      assert :ok = perform_settlement(order)

      reloaded = reload_order(order)
      assert reloaded.status == :paid

      # 信号/通知只一条
      assert [_] =
               all_enqueued(
                 worker: SignalPublishWorker,
                 args: %{"signal_type" => "order.paid"}
               )
               |> Enum.filter(&(get_in(&1.args, ["data", "order_id"]) == order.id))
    end

    test "金额不符（R20）：不落账 + Finding + 告警 telemetry", ctx do
      order = pending_order(ctx)
      stub_channel_paid(order, amount_cents: order.amount_cents + 100)

      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :pending

      assert [%{rule: :payment_amount_mismatch, entity_type: :payment_order}] =
               Ash.read!(Finding, authorize?: false)

      assert event_for(order).status == :processed
    end

    test "回查未支付：无状态变化，等待下个回调/对账", ctx do
      order = pending_order(ctx)

      Fake.script!(
        fetch_transaction: {:ok, %{status: :pending, amount_cents: 0, transaction_id: ""}}
      )

      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :pending

      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status ==
               :payment_pending
    after
      Fake.reset!()
    end

    test "worker 崩溃重试：查单失败可重入，无半落账", ctx do
      order = pending_order(ctx)

      # 第一次执行：渠道查单失联 → {:error, reason}（Oban retryable），业务零变化
      Fake.script!(fetch_transaction: {:error, :channel_unavailable})
      assert {:error, :channel_unavailable} = perform_settlement(order)

      assert reload_order(order).status == :pending

      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status ==
               :payment_pending

      # 重试（Oban 重入）：查单恢复 → 完整落账收敛
      stub_channel_paid(order)
      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :paid
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :confirmed
    end

    test "迟到扣款（AE2）：expired 订单 → refunding + refund job 入队，报名保持 expired", ctx do
      order = pending_order(ctx)

      # 超时扫描先落（U8 的订单+报名联动在彼处以同事务 CAS 驱动；此处等价布置）
      {:ok, order} =
        order
        |> Ash.Changeset.for_update(:expire, %{})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)

      {:ok, _} =
        Cgc2046.Repo.query(
          "UPDATE enrollments SET status = 'expired', expired_at = NOW() WHERE id = $1 AND status = 'payment_pending'",
          [Cgc2046.Repo.uuid!(order.enrollment_id)]
        )

      stub_channel_paid(order)

      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :refunding
      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :expired
    end

    test "免缴竞态（AE3 免缴先落）：confirmed 报名 + 订单作废 → 迟到收款走作废单自动退款链（e2e #1）", ctx do
      order = pending_order(ctx)
      admin = Fixtures.platform_admin("settle-waive-admin")

      {:ok, _} =
        Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
        |> Ash.Changeset.for_update(:waive_payment, %{})
        |> Ash.update(tenant: order.workspace_id, actor: admin)

      # e2e #1：免缴同事务作废 pending 单（本地作废不关渠道单，QR 仍可被支付）
      voided = reload_order(order)
      assert voided.status == :cancelled
      assert voided.cancel_reason == "waived"
      stub_channel_paid(order)

      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :refunding
      assert_enqueued(worker: PaymentRefundWorker, args: %{"order_id" => order.id})

      enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
      assert enrollment.status == :confirmed
    end

    test "F-A 半落账自愈：订单已 paid + 报名仍 payment_pending → 补推进 confirmed + 补通知", ctx do
      order = pending_order(ctx)
      stub_channel_paid(order)

      # 半落账布置：mark_paid 已提交、settle_paid 未执行（两事务间崩溃窗口）
      {:ok, _} =
        order
        |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "half-txn"})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)

      assert :ok = perform_settlement(order)

      assert reload_order(order).status == :paid

      enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
      assert enrollment.status == :confirmed

      # 补发支付成功通知（R22；NotificationWorker unique 幂等，重放不重复）
      assert_enqueued(
        worker: Cgc2046.Workers.NotificationWorker,
        args: %{"user_id" => enrollment.user_id, "template_key" => "payment_succeeded"}
      )

      # 半落账窗口不得误触自动退款
      refute_enqueued(worker: PaymentRefundWorker)
    end

    test "F-I 报名 CAS DB 错误：不误触自动退款，上抛走 Oban 重试；解除后自愈收敛", ctx do
      order = pending_order(ctx)
      stub_channel_paid(order)

      # trigger 注入 settle_paid 的 UPDATE 失败（DB 类错误形状）：
      # payment_pending→confirmed 的状态 CAS 被数据库层拒绝
      Cgc2046.Repo.query!(
        ~s{CREATE OR REPLACE FUNCTION cgc_test_block_settle() RETURNS trigger AS } <>
          ~s{$$ BEGIN RAISE EXCEPTION 'test injected db failure'; END; $$ LANGUAGE plpgsql;}
      )

      Cgc2046.Repo.query!(
        ~s{CREATE TRIGGER block_settle BEFORE UPDATE ON enrollments FOR EACH ROW } <>
          ~s{WHEN (OLD.status = 'payment_pending' AND NEW.status = 'confirmed') } <>
          ~s{EXECUTE FUNCTION cgc_test_block_settle();}
      )

      assert {:error, _db_error} = perform_settlement(order)

      # 占位完好的正常收款不得被 DB 瞬断误判为「报名已流转」而触发自动退款
      refute_enqueued(worker: PaymentRefundWorker)

      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status ==
               :payment_pending

      # 解除注入 → Oban 重试 → 半落账路径自愈收敛（F-A 联动）
      Cgc2046.Repo.query!("DROP TRIGGER block_settle ON enrollments")
      Cgc2046.Repo.query!("DROP FUNCTION cgc_test_block_settle")

      assert :ok = perform_settlement(order)
      assert reload_order(order).status == :paid
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :confirmed
    end
  end

  # ── 布置 ──

  defp pending_order(_ctx) do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("settle-learner")
    insert_identity(learner.id, :wechat, "settle-learner-openid")

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
        tier_snapshot: %{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900},
        expire_at: DateTime.add(DateTime.utc_now(), 2, :hour)
      })
      |> Ash.create(tenant: workspace.id, authorize?: false)

    order
  end

  defp stub_channel_paid(order, overrides \\ []) do
    Fake.script!(
      fetch_transaction:
        {:ok,
         %{
           status: :paid,
           amount_cents: Keyword.get(overrides, :amount_cents, order.amount_cents),
           transaction_id: Keyword.get(overrides, :transaction_id, "txn-fake-1")
         }}
    )
  end

  defp perform_settlement(order) do
    event_id = "evt-" <> order.out_trade_no
    require Ash.Query

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
    require Ash.Query

    WebhookEvent
    |> Ash.Query.filter(event_id == ^("evt-" <> order.out_trade_no))
    |> Ash.read_one!(authorize?: false)
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
end
