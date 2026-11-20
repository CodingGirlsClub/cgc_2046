defmodule Cgc2046.LlmGateway.Workers.CreditExpiryWorker do
  @moduledoc """
  周期性把到期的 active 额度批次标记为 `expired`，并从钱包缓存余额中扣除
  未用部分。

  锁序与 `Cgc2046.LlmGateway.Ledger.settle_usage/3` 一致：先锁 wallet、再锁
  grants。wallet 用 `FOR UPDATE SKIP LOCKED`，与结算并发时跳过、下一拍重试，
  不会形成「结算持 wallet 等 grant、Worker 持 grant 等 wallet」的环。
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    wallet_ids =
      Repo.query!(
        """
        SELECT DISTINCT wallet_id
        FROM llm_credit_grants
        WHERE status = 'active'
          AND expires_at IS NOT NULL
          AND expires_at <= $1
        """,
        [now]
      ).rows
      |> Enum.map(fn [wallet_id] -> wallet_id end)
      |> Enum.sort()

    Enum.each(wallet_ids, fn wallet_id_bin ->
      Repo.transaction(fn ->
        case Repo.query!(
               "SELECT id FROM llm_wallets WHERE id = $1 FOR UPDATE SKIP LOCKED",
               [wallet_id_bin]
             ).rows do
          [[_id]] ->
            Ledger.expire_wallet_grants!(wallet_id_bin, now)

          [] ->
            :skipped
        end
      end)
    end)

    :ok
  end
end
