defmodule Cgc2046.LlmGateway.Workers.CreditExpiryWorker do
  @moduledoc """
  周期性把到期的 active 额度批次标记为 `expired`，并从钱包缓存余额中扣除
  未用部分。使用 `FOR UPDATE SKIP LOCKED`，多实例/重入不会重复扣减。
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Cgc2046.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      expired_rows =
        Repo.query!(
          """
          SELECT id, wallet_id, remaining_mc
          FROM llm_credit_grants
          WHERE status = 'active'
            AND expires_at IS NOT NULL
            AND expires_at <= $1
          FOR UPDATE SKIP LOCKED
          """,
          [now]
        ).rows

      Enum.each(expired_rows, fn [grant_id_bin, wallet_id_bin, remaining_mc] ->
        Repo.query!(
          """
          UPDATE llm_credit_grants
          SET remaining_mc = 0, status = 'expired', updated_at = $2
          WHERE id = $1
          """,
          [grant_id_bin, now]
        )

        if remaining_mc > 0 do
          Repo.query!(
            """
            UPDATE llm_wallets
            SET cached_balance_mc = GREATEST(0, cached_balance_mc - $2),
                held_mc = LEAST(held_mc, GREATEST(0, cached_balance_mc - $2)),
                updated_at = $3
            WHERE id = $1
            """,
            [wallet_id_bin, remaining_mc, now]
          )
        end
      end)

      length(expired_rows)
    end)

    :ok
  end
end
