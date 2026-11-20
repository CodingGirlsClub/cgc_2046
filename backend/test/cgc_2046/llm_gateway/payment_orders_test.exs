defmodule Cgc2046.LlmGateway.PaymentOrdersTest do
  @moduledoc """
  Phase 3B：独立 LLM 收银台创单、幂等、回调落账、金额不符与工作台池充值。
  """

  use Cgc2046.DataCase, async: false
  use Oban.Testing, repo: Cgc2046.Repo

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrder
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.LlmGateway.Workers.LlmPaymentSettlementWorker
  alias Cgc2046.Payments.Providers.{DevFake, Fake}
  alias Cgc2046.Payments.ReplaySettlement
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo

  defmodule TxProbeProvider do
    @behaviour Cgc2046.Payments.Provider

    @impl true
    def create_payment(order, ctx) do
      if pid = Process.get({__MODULE__, :caller}) do
        send(pid, {:create_payment_called, Cgc2046.Repo.in_transaction?(), order.out_trade_no})
      end

      Cgc2046.Payments.Providers.Fake.create_payment(order, ctx)
    end

    @impl true
    def fetch_transaction(out_trade_no),
      do: Cgc2046.Payments.Providers.Fake.fetch_transaction(out_trade_no)

    @impl true
    def refund(order), do: Cgc2046.Payments.Providers.Fake.refund(order)

    @impl true
    def verify_webhook(body, headers),
      do: Cgc2046.Payments.Providers.Fake.verify_webhook(body, headers)

    @impl true
    def fetch_statement(date), do: Cgc2046.Payments.Providers.Fake.fetch_statement(date)
  end

  test "个人加油包：创单快照、LLM_ 单号、同幂等键返回原单" do
    user = Fixtures.register_user("llm-order")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 1_000,
        idempotency_key: "pack-001"
      })

    assert order.status == :pending
    assert order.workspace_id == nil
    assert order.amount_cents == 1_000
    assert order.credits_mc == 10_000_000
    assert String.starts_with?(order.out_trade_no, "LLM_")
    assert order.credential["type"] == "jsapi"

    {:ok, replay} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 1_000,
        idempotency_key: "pack-001"
      })

    assert replay.id == order.id
    assert replay.out_trade_no == order.out_trade_no
    assert replay.credential == order.credential
  end

  test "渠道下单失败将订单标记为 cancelled 且同 key 重放不再调用渠道" do
    user = Fixtures.register_user("llm-order-fail")
    with_tx_probe_provider()
    Fake.script!(create_payment: {:error, :channel_create_failed})

    assert {:error, :provider_failed} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 1_000,
               idempotency_key: "pack-fail"
             })

    assert_receive {:create_payment_called, false, out_trade_no}

    {:ok, cancelled} = PaymentOrders.find_by_out_trade_no(out_trade_no)
    assert cancelled.status == :cancelled
    assert cancelled.credential == nil

    assert {:error, :provider_failed} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 1_000,
               idempotency_key: "pack-fail"
             })

    refute_received {:create_payment_called, _, _}

    assert PaymentOrders.find_by_out_trade_no("LLM_missing") == {:error, :not_found}
  after
    Fake.reset!()
  end

  test "Provider.create_payment/2 在 Repo.transaction 外部执行，且 pending 无凭据订单重放可恢复" do
    user = Fixtures.register_user("llm-order-no-tx")
    with_tx_probe_provider()

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "alipay_qr",
        amount_cents: 5_000,
        idempotency_key: "pack-no-tx"
      })

    assert_receive {:create_payment_called, false, out_trade_no}
    assert out_trade_no == order.out_trade_no
    assert order.credential["out_trade_no"] == order.out_trade_no

    # 模拟 Phase A 已落库但 Phase B 尚未回写 credential 的中断态
    Repo.query!(
      "UPDATE llm_payment_orders SET credential = NULL WHERE id = $1",
      [Ecto.UUID.dump!(order.id)]
    )

    {:ok, recovered} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "alipay_qr",
        amount_cents: 5_000,
        idempotency_key: "pack-no-tx"
      })

    assert_receive {:create_payment_called, false, ^out_trade_no}
    assert recovered.id == order.id
    assert recovered.credential["out_trade_no"] == order.out_trade_no
  after
    Fake.reset!()
  end

  test "同幂等键但载荷字段不一致返回 :idempotency_conflict" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

    {:ok, order} =
      PaymentOrders.create(owner, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 1_000,
        idempotency_key: "idem-payload-check"
      })

    assert order.status == :pending

    # 金额不匹配
    assert {:error, :idempotency_conflict} =
             PaymentOrders.create(owner, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 5_000,
               idempotency_key: "idem-payload-check"
             })

    # 渠道不匹配
    assert {:error, :idempotency_conflict} =
             PaymentOrders.create(owner, %{
               order_kind: "llm_credit_pack",
               provider: "alipay_qr",
               amount_cents: 1_000,
               idempotency_key: "idem-payload-check"
             })

    # 类型不匹配
    assert {:error, :idempotency_conflict} =
             PaymentOrders.create(owner, %{
               order_kind: "llm_subscription",
               provider: "wechat_native",
               amount_cents: 2_900,
               idempotency_key: "idem-payload-check"
             })

    # 工作台归属不匹配
    assert {:error, :idempotency_conflict} =
             PaymentOrders.create(owner, %{
               order_kind: "llm_workspace_pool_topup",
               provider: "wechat_native",
               workspace_id: workspace.id,
               amount_cents: 10_000,
               idempotency_key: "idem-payload-check"
             })
  end

  test "个人加油包结算：入钱包、payment_order_id 落链、重复回调不重复入账" do
    user = Fixtures.register_user("llm-settle-pack")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 1_000,
        idempotency_key: "settle-pack"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 1_000, transaction_id: "txn-pack"}}
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
        provider: "alipay_qr",
        amount_cents: 2_900,
        idempotency_key: "settle-sub"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 2_900, transaction_id: "txn-sub"}}
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
        amount_cents: 10_000,
        idempotency_key: "pool-001"
      })

    assert order.workspace_id == workspace.id

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 10_000, transaction_id: "txn-pool"}}
    )

    assert :ok = settle(event)

    assert {:ok, %{credit_pool_mc: 100_000_000}} = workspace_pool(workspace.id)

    assert :ok = settle(event)
    assert {:ok, %{credit_pool_mc: 100_000_000}} = workspace_pool(workspace.id)

    assert {:error, :forbidden} =
             PaymentOrders.create(member, %{
               order_kind: "llm_workspace_pool_topup",
               provider: "wechat_native",
               workspace_id: workspace.id,
               amount_cents: 10_000,
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
        amount_cents: 1_000,
        idempotency_key: "settle-mismatch"
      })

    event = webhook_event(order.out_trade_no)

    Fake.script!(
      fetch_transaction: {:ok, %{status: :paid, amount_cents: 999, transaction_id: "txn-wrong"}}
    )

    assert :ok = settle(event)
    {:ok, still_pending} = PaymentOrders.find_by_out_trade_no(order.out_trade_no)
    assert still_pending.status == :pending
    assert Ledger.ensure_wallet!(user.id).cached_balance_mc == 0

    finding =
      Finding
      |> Ash.Query.filter(rule == :payment_amount_mismatch and entity_id == ^order.id)
      |> Ash.read_one!(authorize?: false)

    assert finding.detail["order_source"] == "llm_payment_order"
    assert finding.detail["expected_cents"] == 1_000
    assert finding.detail["channel_cents"] == 999
    assert finding.detail["local_cents"] == 1_000
  after
    Fake.reset!()
  end

  test "已取消/已过期 LLM 订单收到迟到已付回调：不入账、不翻 paid、落 :llm_closed_order_paid Finding" do
    user = Fixtures.register_user("llm-settle-closed")
    with_tx_probe_provider()
    Fake.script!(create_payment: {:error, :channel_create_failed})

    assert {:error, :provider_failed} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 1_000,
               idempotency_key: "closed-late-paid"
             })

    assert_receive {:create_payment_called, false, out_trade_no}
    {:ok, cancelled_order} = PaymentOrders.find_by_out_trade_no(out_trade_no)
    assert cancelled_order.status == :cancelled

    event = webhook_event(out_trade_no)

    Fake.script!(
      fetch_transaction:
        {:ok, %{status: :paid, amount_cents: 1_000, transaction_id: "txn-late-cancelled"}}
    )

    assert :ok = settle(event)

    {:ok, reloaded} = PaymentOrders.find_by_out_trade_no(out_trade_no)
    assert reloaded.status == :cancelled
    assert Ledger.ensure_wallet!(user.id).cached_balance_mc == 0
    assert Ash.get!(WebhookEvent, event.id, authorize?: false).status == :processed

    finding =
      Finding
      |> Ash.Query.filter(rule == :llm_closed_order_paid and entity_id == ^cancelled_order.id)
      |> Ash.read_one!(authorize?: false)

    assert finding.entity_type == :payment_order
    assert finding.workspace_id == nil

    assert finding.detail == %{
             "order_source" => "llm_payment_order",
             "out_trade_no" => out_trade_no,
             "status" => "cancelled",
             "amount_cents" => 1_000,
             "transaction_id" => "txn-late-cancelled"
           }
  after
    Fake.reset!()
  end

  test "ReplaySettlement.run/1 与 DevFake.fetch_transaction/1 支持 LLM_ 订单收敛" do
    user = Fixtures.register_user("llm-ops-replay")

    {:ok, order} =
      PaymentOrders.create(user, %{
        order_kind: "llm_credit_pack",
        provider: "alipay_qr",
        amount_cents: 5_000,
        idempotency_key: "ops-replay-001"
      })

    assert {:ok,
            %{
              status: :paid,
              amount_cents: 5_000,
              transaction_id: "dev-fake-" <> txn_suffix
            }} = DevFake.fetch_transaction(order.out_trade_no)

    assert txn_suffix == order.out_trade_no
    assert {:error, :order_not_found} = DevFake.fetch_transaction("LLM_missing_dev_fake")

    assert {:error, :order_not_found} = ReplaySettlement.run("LLM_missing_replay")

    assert {:ok, %{event_id: event_id, job_id: job_id}} = ReplaySettlement.run(order.out_trade_no)
    assert is_binary(event_id) and is_integer(job_id)

    # 重复 run 幂等复用同一事件
    assert {:ok, %{event_id: ^event_id, job_id: ^job_id}} =
             ReplaySettlement.run(order.out_trade_no)

    event = Ash.get!(WebhookEvent, event_id, authorize?: false)
    assert event.provider == :alipay
    assert event.event_id == "replay-" <> order.out_trade_no
    assert event.payload == %{"out_trade_no" => order.out_trade_no}

    assert_enqueued(
      worker: LlmPaymentSettlementWorker,
      args: %{"webhook_event_id" => event_id}
    )

    assert [] = all_enqueued(worker: PaymentSettlementWorker)

    Fake.script!(
      fetch_transaction:
        {:ok, %{status: :paid, amount_cents: 5_000, transaction_id: "txn-replay-llm"}}
    )

    assert :ok = perform_job(LlmPaymentSettlementWorker, %{"webhook_event_id" => event_id})
    {:ok, paid} = PaymentOrders.find_by_out_trade_no(order.out_trade_no)
    assert paid.status == :paid
    assert Ledger.fetch_wallet!(user.id).cached_balance_mc == 50_000_000
  after
    Fake.reset!()
  end

  test "参数校验：未知类型/未签约渠道/SKU 档位与范围/缺工作台" do
    %{owner: user, workspace: workspace} = Fixtures.workspace_with_member()

    base = %{
      order_kind: "llm_credit_pack",
      provider: "wechat_native",
      amount_cents: 1_000,
      idempotency_key: "validate"
    }

    assert {:error, :invalid_kind} =
             PaymentOrders.create(user, Map.put(base, :order_kind, "nope"))

    assert {:error, :invalid_provider} =
             PaymentOrders.create(user, Map.put(base, :provider, "paypal"))

    # 未签约渠道 alipay_page / alipay_wap 均被拒
    assert {:error, :invalid_provider} =
             PaymentOrders.create(user, Map.put(base, :provider, "alipay_page"))

    assert {:error, :invalid_provider} =
             PaymentOrders.create(user, Map.put(base, :provider, "alipay_wap"))

    # SKU 档位/范围校验
    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, Map.put(base, :amount_cents, 0))

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, Map.put(base, :amount_cents, 1))

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, %{
               base
               | order_kind: "llm_subscription",
                 amount_cents: 1_000
             })

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, %{
               base
               | order_kind: "llm_workspace_pool_topup",
                 amount_cents: 9_999
             })

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, %{
               base
               | order_kind: "llm_workspace_pool_topup",
                 amount_cents: 10_000_001
             })

    assert {:ok, _} =
             PaymentOrders.create(user, %{
               order_kind: "llm_workspace_pool_topup",
               provider: "alipay_qr",
               workspace_id: workspace.id,
               amount_cents: 10_000_000,
               idempotency_key: "validate-max-pool"
             })

    assert {:error, :workspace_required} =
             PaymentOrders.create(user, %{
               base
               | order_kind: "llm_workspace_pool_topup",
                 amount_cents: 10_000
             })
  end

  test "SKU 规则支持通过 app env :llm_gateway_checkout_skus 覆盖" do
    user = Fixtures.register_user("llm-order-sku-env")
    original = Application.get_env(:cgc_2046, :llm_gateway_checkout_skus)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:cgc_2046, :llm_gateway_checkout_skus)
      else
        Application.put_env(:cgc_2046, :llm_gateway_checkout_skus, original)
      end
    end)

    Application.put_env(:cgc_2046, :llm_gateway_checkout_skus, %{llm_credit_pack: [2_500]})

    assert {:error, :invalid_amount} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 1_000,
               idempotency_key: "sku-env-reject"
             })

    assert {:ok, order} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 2_500,
               idempotency_key: "sku-env-accept"
             })

    assert order.amount_cents == 2_500
  end

  test "PaymentOrder Ash 资源仅暴露读面，不接受调用方经 Ash action 直接写单" do
    actions = Ash.Resource.Info.actions(PaymentOrder)
    assert actions != []
    assert Enum.all?(actions, &(&1.type == :read))
    assert Ash.Resource.Info.action(PaymentOrder, :create) == nil

    user = Fixtures.register_user("llm-order-ash-create")

    assert_raise ArgumentError, ~r/No such create action/, fn ->
      PaymentOrder
      |> Ash.Changeset.for_create(:create, %{
        user_id: user.id,
        order_kind: :llm_credit_pack,
        provider: :wechat_native,
        out_trade_no: "LLM_forged_12345678901234567890",
        amount_cents: 100,
        credits_mc: 999_999_999,
        status: :paid,
        idempotency_key: "forged-001"
      })
      |> Ash.create(actor: user)
    end
  end

  defmodule SerializedProvider do
    def create_payment(order, _opts) do
      counter = :persistent_term.get({__MODULE__, :counter})
      :counters.add(counter, 1, 1)
      Process.sleep(60)
      {:ok, %{"type" => "qr_code", "code_url" => "weixin://serial/#{order.out_trade_no}"}}
    end
  end

  defmodule CancelDuringProviderCall do
    def create_payment(order, _opts) do
      Cgc2046.Repo.query!(
        "UPDATE llm_payment_orders SET status = 'cancelled' WHERE out_trade_no = $1",
        [order.out_trade_no]
      )

      {:ok, %{"type" => "qr_code", "code_url" => "weixin://should-not-leak"}}
    end
  end

  test "并发同幂等键串行化 Phase B：渠道只调一次且返回同一持久化凭证" do
    counter = :counters.new(1, [])
    :persistent_term.put({SerializedProvider, :counter}, counter)
    original = Application.get_env(:cgc_2046, :payments_providers)

    Application.put_env(:cgc_2046, :payments_providers, %{
      wechat: SerializedProvider,
      alipay: SerializedProvider
    })

    on_exit(fn ->
      :persistent_term.erase({SerializedProvider, :counter})
      Application.put_env(:cgc_2046, :payments_providers, original)
    end)

    user = Fixtures.register_user("llm-concurrent-idem")

    params = %{
      order_kind: "llm_credit_pack",
      provider: "wechat_native",
      amount_cents: 1_000,
      idempotency_key: "idem-concurrent-001"
    }

    parent = self()

    t1 =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        PaymentOrders.create(user, params)
      end)

    t2 =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        PaymentOrders.create(user, params)
      end)

    assert {:ok, o1} = Task.await(t1, 5_000)
    assert {:ok, o2} = Task.await(t2, 5_000)
    assert o1.id == o2.id
    assert o1.credential == o2.credential
    assert :counters.get(counter, 1) == 1
  end

  test "渠道返回前订单已被取消时，绝不把未落库二维码返回给用户" do
    original = Application.get_env(:cgc_2046, :payments_providers)

    Application.put_env(:cgc_2046, :payments_providers, %{
      wechat: CancelDuringProviderCall,
      alipay: CancelDuringProviderCall
    })

    on_exit(fn ->
      Application.put_env(:cgc_2046, :payments_providers, original)
    end)

    user = Fixtures.register_user("llm-cancelled-race")

    assert {:error, :provider_failed} =
             PaymentOrders.create(user, %{
               order_kind: "llm_credit_pack",
               provider: "wechat_native",
               amount_cents: 1_000,
               idempotency_key: "idem-cancelled-race-001"
             })
  end

  defp with_tx_probe_provider do
    original = Application.get_env(:cgc_2046, :payments_providers)
    Process.put({TxProbeProvider, :caller}, self())

    Application.put_env(:cgc_2046, :payments_providers, %{
      wechat: TxProbeProvider,
      alipay: TxProbeProvider
    })

    on_exit(fn ->
      Process.delete({TxProbeProvider, :caller})
      Application.put_env(:cgc_2046, :payments_providers, original)
    end)
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
