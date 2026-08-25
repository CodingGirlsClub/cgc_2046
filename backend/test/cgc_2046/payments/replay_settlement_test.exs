defmodule Cgc2046.Payments.ReplaySettlementTest do
  @moduledoc """
  webhook 丢失兜底收敛（生产实证 2026-08-25：微信回调解密崩溃后事件永不
  落库，用户已扣款、订单停 pending）。

  核心契约：run/1 造 replay 事件 + 入队 settlement worker——状态收敛全部
  由 worker 标准落账链完成（查单权威 → mark_paid CAS → settle_paid CAS →
  通知），本模块零状态直改；幂等 = 唯一索引去重 + worker CAS（重复 run
  等价渠道重复投递，R21 语义）。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Payments.{Order, Providers.Fake, ReplaySettlement, WebhookEvent}
  alias Cgc2046.Workers.{PaymentSettlementWorker, SignalPublishWorker}

  @tier_id "33333333-3333-3333-3333-333333333333"

  describe "run/1 收敛" do
    test "pending 订单 + 渠道已扣款 → 事件落库 + job 入队 → worker 落账全链收敛" do
      order = pending_order()
      stub_channel_paid(order)

      assert {:ok, %{event_id: event_id, job_id: job_id}} =
               ReplaySettlement.run(order.out_trade_no)

      assert is_binary(event_id) and is_integer(job_id)

      # 事件形状：payload 只带 out_trade_no（worker 自查单，不依赖回调明文）
      event = Ash.get!(WebhookEvent, event_id, authorize?: false)
      assert event.provider == :wechat
      assert event.event_id == "replay-" <> order.out_trade_no
      assert event.payload == %{"out_trade_no" => order.out_trade_no}

      # worker 消费（Oban testing 模式手动执行）
      assert :ok = perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event_id})

      reloaded = reload_order(order)
      assert reloaded.status == :paid
      assert reloaded.transaction_id == "txn-fake-1"
      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status == :confirmed

      assert_enqueued(
        worker: SignalPublishWorker,
        args: %{"signal_type" => "order.paid", "data" => %{"order_id" => order.id}}
      )

      assert event
             |> Ash.reload!(authorize?: false)
             |> Map.get(:status) == :processed
    after
      Fake.reset!()
    end

    test "幂等：同单重复 run → 复用事件再入队，业务状态只变一次" do
      order = pending_order()
      stub_channel_paid(order)

      assert {:ok, first} = ReplaySettlement.run(order.out_trade_no)
      assert {:ok, second} = ReplaySettlement.run(order.out_trade_no)

      # 唯一索引去重：两次 run 落的是同一条事件；job 侧 Oban worker unique
      # （period 300s）同样去重——重复 run 等价渠道重复投递，全链只收敛一次
      assert first.event_id == second.event_id
      assert first.job_id == second.job_id

      assert :ok = perform_job(PaymentSettlementWorker, %{"webhook_event_id" => first.event_id})

      assert reload_order(order).status == :paid

      paid_signals =
        all_enqueued(worker: SignalPublishWorker)
        |> Enum.filter(&(get_in(&1.args, ["data", "order_id"]) == order.id))

      assert length(paid_signals) == 1
    after
      Fake.reset!()
    end

    test "订单不存在 → {:error, :order_not_found}（不造事件不入队）" do
      assert {:error, :order_not_found} = ReplaySettlement.run("CGC-nonexistent")

      assert Ash.read!(WebhookEvent, authorize?: false)
             |> Enum.filter(&String.starts_with?(&1.event_id, "replay-")) == []

      assert [] = all_enqueued(worker: PaymentSettlementWorker)
    end

    test "渠道未支付 → 不落账（worker 查单分支裁决，非本模块职责）" do
      order = pending_order()

      Fake.script!(
        fetch_transaction: {:ok, %{status: :pending, amount_cents: 0, transaction_id: ""}}
      )

      assert {:ok, %{event_id: event_id}} = ReplaySettlement.run(order.out_trade_no)
      assert :ok = perform_job(PaymentSettlementWorker, %{"webhook_event_id" => event_id})

      assert reload_order(order).status == :pending

      assert Ash.get!(Enrollment, order.enrollment_id, authorize?: false).status ==
               :payment_pending
    after
      Fake.reset!()
    end
  end

  # ── 布置（造数同 payment_settlement_worker_test 先例）──

  defp pending_order do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        pricing_enabled: true,
        price_tiers: [%{"id" => @tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("replay-learner")
    insert_identity(learner.id, :wechat, "replay-learner-openid")

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

  defp stub_channel_paid(order) do
    Fake.script!(
      fetch_transaction:
        {:ok, %{status: :paid, amount_cents: order.amount_cents, transaction_id: "txn-fake-1"}}
    )
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
