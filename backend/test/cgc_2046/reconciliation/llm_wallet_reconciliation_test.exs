defmodule Cgc2046.Reconciliation.LlmWalletReconciliationTest do
  @moduledoc """
  Phase 3A：llm_wallet_balance_mismatch 规则。缓存余额应等于活跃授信
  remaining_mc 之和；held 是缓存内部冻结，不得参与等式（否则在途流会被误报）。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.Ledger
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
    assert finding() == nil
  end

  defp finding do
    Finding
    |> Ash.Query.filter(rule == :llm_wallet_balance_mismatch)
    |> Ash.read_one!(authorize?: false)
  end
end
