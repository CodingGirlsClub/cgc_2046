defmodule Cgc2046.LlmGateway.PaymentOrdersTest do
  @moduledoc """
  Phase 3B：独立 LLM 收银台创单、幂等、回调落账、金额不符与工作台池充值。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.LlmGateway.Workers.LlmPaymentSettlementWorker
  alias Cgc2046.Payments.Providers.Fake
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo

  test "个人加油包：创单快照、LLM_ 单号、同幂等键返回原单" do
    user = Fixtures.register_user("llm-order")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 100,
        idempotency_key: "pack-001"
      })

    assert order.status == :pending
    assert order.workspace_id == nil
    assert order.amount_cents == 100
    assert order.credits_mc == 1_000_000
    assert String.starts_with?(order.out_trade_no, "LLM_")
    assert order.credential["type"] == "jsapi"

    {:ok, replay} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 100,
        idempotency_key: "pack-001"
      })

    assert replay.id == order.id
    assert replay.out_trade_no == order.out_trade_no
    assert replay.credential == order.credential
  end

  test "渠道下单失败不落订单" do
    user = Fixtures.register_user("llm-order-fail")
    Fake.script!(create_payment: {:error, :channel_create_failed})

    assert {:error, :provider_failed} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 100,
               idempotency_key: "pack-fail"
             })

    assert PaymentOrders.find_by_out_trade_no("LLM_missing") == {:error, :not_found}
  after
    Fake.reset!()
  end

  test "个人加油包结算：入钱包、payment_order_id 落链、重复回调不重复入账" do
    user = Fixtures.register_user("llm-settle-pack")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 100,
        idempotency_key: "settle-pack"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 100, transaction_id: "txn-pack"}}
    )

    assert :ok = settle(event)
    {:ok, paid} = PaymentOrders.find_by_out_trade_no(order.out_trade_no)
    assert paid.status == :paid
    assert paid.transaction_id == "txn-pack"

    assert %{rows: [[payment_order_id]]} =
             Repo.query!(
               "SELECT payment_order_id FROM llm_credit_grants WHERE user_id = $1 AND status = 'active'",
               [Ecto.UUID.dump!(user.id)]
             )

    assert Ecto.UUID.load!(payment_order_id) == order.id

    wallet = Ledger.fetch_wallet!(user.id)
    assert wallet.cached_balance_mc == order.credits_mc

    assert :ok = settle(event)
    assert Ledger.fetch_wallet!(user.id).cached_balance_mc == order.credits_mc
    assert Ash.get!(WebhookEvent, event.id, authorize?: false).status == :processed
  after
    Fake.reset!()
  end

  test "个人订阅结算：30 天有效期；订阅与永久包来源类型正确" do
    user = Fixtures.register_user("llm-settle-sub")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_subscription",
        provider: "alipay_page",
        amount_cents: 100,
        idempotency_key: "settle-sub"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 100, transaction_id: "txn-sub"}}
    )

    assert :ok = settle(event)

    assert %{source_type: :subscription, expires_at: expires_at, initial_mc: initial_mc} =
             active_grant(user)

    assert initial_mc == order.credits_mc
    assert DateTime.diff(expires_at, DateTime.utc_now(), :second) > 29 * 86_400
  after
    Fake.reset!()
  end

  test "工作台池充值：Owner 可创单并结算；普通成员 forbidden" do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

    {:ok, order} =
      PaymentOrders.create(owner, %{
        order_kind: "llm_workspace_pool_topup",
        provider: "wechat_native",
        workspace_id: workspace.id,
        amount_cents: 100,
        idempotency_key: "pool-001"
      })

    assert order.workspace_id == workspace.id

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 100, transaction_id: "txn-pool"}}
    )

    assert :ok = settle(event)

    assert {:ok, %{credit_pool_mc: 1_000_000}} = workspace_pool(workspace.id)

    assert :ok = settle(event)
    assert {:ok, %{credit_pool_mc: 1_000_000}} = workspace_pool(workspace.id)

    assert {:error, :forbidden} =
             PaymentOrders.create(member, %{
               order_kind: "llm_workspace_pool_topup",
               provider: "wechat_native",
               workspace_id: workspace.id,
               amount_cents: 100,
               idempotency_key: "pool-member"
             })
  after
    Fake.reset!()
  end

  test "渠道金额不符：不落账、订单保持 pending、写 payment_amount_mismatch Finding" do
    user = Fixtures.register_user("llm-settle-mismatch")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 100,
        idempotency_key: "settle-mismatch"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 99, transaction_id: "txn-wrong"}}
    )

    assert :ok = settle(event)
    {:ok, still_pending} = PaymentOrders.find_by_out_trade_no(order.out_trade_no)
    assert still_pending.status == :pending
    assert Ledger.ensure_wallet!(user.id).cached_balance_mc == 0

    finding =
      Finding
      |> Ash.Query.filter(rule == :payment_amount_mismatch and entity_id == ^order.id)
      |> Ash.read_one!(authorize?: false)

    assert finding.detail["channel_cents"] == 99
    assert finding.detail["local_cents"] == 100
  after
    Fake.reset!()
  end

  test "参数校验：未知类型/渠道、金额、缺工作台" do
    user = Fixtures.register_user("llm-order-validate")

    base = %{
      order_kind: "llm_credit_pack",
      provider: "wechat_native",
      amount_cents: 100,
      idempotency_key: "validate"
    }

    assert {:error, :invalid_kind} =
             PaymentOrders.create(user, Map.put(base, :order_kind, "nope"))

    assert {:error, :invalid_provider} =
             PaymentOrders.create(user, Map.put(base, :provider, "paypal"))

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, Map.put(base, :amount_cents, 0))

    assert {:error, :workspace_required} =
             PaymentOrders.create(user, %{base | order_kind: "llm_workspace_pool_topup"})
  end

  defp settle(event) do
    LlmPaymentSettlementWorker.perform(%Oban.Job{
      args: %{"webhook_event_id" => event.id}
    })
  end

  defp webhook_event(out_trade_no) do
    WebhookEvent
    |> Ash.Changeset.for_create(:create, %{
      provider: :wechat,
      event_id: Ecto.UUID.generate(),
      payload: %{"out_trade_no" => out_trade_no}
    })
    |> Ash.create!(authorize?: false)
  end

  defp active_grant(user) do
    Cgc2046.LlmGateway.CreditGrant
    |> Ash.Query.filter(user_id == ^user.id and status == :active)
    |> Ash.read_one!(authorize?: false)
  end

  defp workspace_pool(workspace_id) do
    Repo.query!("SELECT credit_pool_mc FROM workspaces WHERE id = $1", [
      Ecto.UUID.dump!(workspace_id)
    ])
    |> case do
      %{rows: [[credit_pool_mc]]} -> {:ok, %{credit_pool_mc: credit_pool_mc}}
    end
  end
end
