defmodule Cgc2046.Reconciliation.LlmWalletReconciliationTest do
  @moduledoc """
  Phase 3A：llm_wallet_balance_mismatch 规则。缓存余额应等于活跃授信
  remaining_mc 之和；held 是缓存内部冻结，不得参与等式（否则在途流会被误报）。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Reconciliation.ReconciliationScanWorker
  alias Cgc2046.Repo

  test "缓存余额漂移命中；修好后下一拍自消；在途 hold 不误报" do
    user = Fixtures.register_user("llm-recon")

    {:ok, _wallet} =
      Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000_000, source_type: :pack})

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding() == nil

    {:ok, hold} = Ledger.acquire_hold(user.id, 1_000_000)
    assert hold.held_mc == 1_000_000

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding() == nil, "held_mc 是缓存内冻结，不应参与余额等式"

    wallet = Ledger.fetch_wallet!(user.id)

    Repo.query!(
      "UPDATE llm_wallets SET cached_balance_mc = cached_balance_mc + 1 WHERE id = $1",
      [Ecto.UUID.dump!(wallet.id)]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})

    finding = finding()
    assert finding.rule == :llm_wallet_balance_mismatch
    assert finding.entity_type == :user
    assert finding.entity_id == user.id
    assert finding.detail["wallet_id"] == wallet.id
    assert finding.detail["cached_balance_mc"] == 10_000_001
    assert finding.detail["grants_remaining_mc"] == 10_000_000
    assert finding.detail["held_mc"] == 1_000_000
    assert finding.detail["available_mc"] == 9_000_001

    Repo.query!(
      """
      UPDATE llm_wallets
      SET cached_balance_mc = (
        SELECT COALESCE(SUM(remaining_mc), 0)
        FROM llm_credit_grants
        WHERE wallet_id = $1 AND status = 'active'
      )
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(wallet.id)]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding(:llm_wallet_balance_mismatch) == nil
  end

  test "llm_wallet_held_mismatch: held_mc 与活跃 holds 漂移命中，修好后自消" do
    user = Fixtures.register_user("llm-recon-held")

    {:ok, _wallet} =
      Ledger.grant_personal_credits(user.id, %{amount_mc: 10_000_000, source_type: :pack})

    {:ok, hold} = Ledger.acquire_hold(user.id, 1_000_000)
    assert hold.held_mc == 1_000_000

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding(:llm_wallet_held_mismatch, user.id) == nil

    # 篡改 wallet.held_mc 使其与活跃 llm_wallet_holds 之和不符
    Repo.query!(
      "UPDATE llm_wallets SET held_mc = held_mc + 500 WHERE id = $1",
      [Ecto.UUID.dump!(hold.wallet_id)]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})

    f = finding(:llm_wallet_held_mismatch, user.id)
    assert f.rule == :llm_wallet_held_mismatch
    assert f.entity_type == :user
    assert f.entity_id == user.id
    assert f.detail["wallet_id"] == hold.wallet_id
    assert f.detail["held_mc"] == 1_000_500
    assert f.detail["active_holds_mc"] == 1_000_000

    # 修复后下一拍自消
    Repo.query!(
      "UPDATE llm_wallets SET held_mc = 1000000 WHERE id = $1",
      [Ecto.UUID.dump!(hold.wallet_id)]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding(:llm_wallet_held_mismatch, user.id) == nil
  end

  test "llm_paid_order_without_grant: 已付个人订单缺授信或 initial_mc 漂移命中，补齐后自消" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    now = DateTime.utc_now()

    # 1. 工作台池充值 paid 订单不走个人 llm_credit_grants，不应误报
    {:ok, pool_order} =
      PaymentOrders.create(owner, %{
        order_kind: "llm_workspace_pool_topup",
        provider: "wechat_native",
        workspace_id: workspace.id,
        amount_cents: 10_000,
        idempotency_key: "recon-pool-paid"
      })

    Repo.query!(
      "UPDATE llm_payment_orders SET status = 'paid', paid_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(pool_order.id), now]
    )

    # 2. 个人加油包订单已 paid 但缺失 llm_credit_grants
    {:ok, pack_order} =
      PaymentOrders.create(owner, %{
        order_kind: "llm_credit_pack",
        provider: "wechat_native",
        amount_cents: 1_000,
        idempotency_key: "recon-pack-no-grant"
      })

    Repo.query!(
      "UPDATE llm_payment_orders SET status = 'paid', paid_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(pack_order.id), now]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})

    assert finding(:llm_paid_order_without_grant, pool_order.id) == nil

    missing_finding = finding(:llm_paid_order_without_grant, pack_order.id)
    assert missing_finding.entity_type == :payment_order
    assert missing_finding.entity_id == pack_order.id
    assert missing_finding.detail["out_trade_no"] == pack_order.out_trade_no
    assert missing_finding.detail["credits_mc"] == pack_order.credits_mc
    assert missing_finding.detail["grant_id"] == nil

    # 3. 补发一笔 initial_mc 不符的 grant -> 仍命中（金额漂移）
    {:ok, _wallet} =
      Ledger.grant_personal_credits(owner.id, %{
        amount_mc: pack_order.credits_mc - 1,
        source_type: :pack,
        payment_order_id: pack_order.id
      })

    ReconciliationScanWorker.perform(%Oban.Job{})

    mismatch_finding = finding(:llm_paid_order_without_grant, pack_order.id)
    assert mismatch_finding.detail["grant_id"] != nil
    assert mismatch_finding.detail["grant_initial_mc"] == pack_order.credits_mc - 1

    # 4. 修正 grant.initial_mc == order.credits_mc -> 下一拍自消
    Repo.query!(
      """
      UPDATE llm_credit_grants
      SET initial_mc = $2, remaining_mc = $2
      WHERE payment_order_id = $1
      """,
      [Ecto.UUID.dump!(pack_order.id), pack_order.credits_mc]
    )

    ReconciliationScanWorker.perform(%Oban.Job{})
    assert finding(:llm_paid_order_without_grant, pack_order.id) == nil
  end

  defp finding(rule \\ :llm_wallet_balance_mismatch) do
    Finding
    |> Ash.Query.filter(rule == ^rule)
    |> Ash.read_one!(authorize?: false)
  end

  defp finding(rule, entity_id) do
    Finding
    |> Ash.Query.filter(rule == ^rule and entity_id == ^entity_id)
    |> Ash.read_one!(authorize?: false)
  end
end
