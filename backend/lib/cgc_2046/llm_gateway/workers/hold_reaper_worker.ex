defmodule Cgc2046.LlmGateway.Workers.HoldReaperWorker do
  @moduledoc """
  Releases abandoned per-request holds whose `expires_at` passed without a
  settlement (killed request process / BEAM restart). Locks wallets before
  holds, matching `settle_usage/4`'s wallet -> hold order.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Cgc2046.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      wallet_ids =
        Repo.query!(
          """
          SELECT DISTINCT wallet_id
          FROM llm_wallet_holds
          WHERE status = 'active' AND expires_at <= $1
          """,
          [now]
        ).rows
        |> Enum.map(fn [wallet_id] -> wallet_id end)
        |> Enum.sort()

      locked_wallet_ids =
        Enum.filter(wallet_ids, fn wallet_id_bin ->
          Repo.query!(
            "SELECT id FROM llm_wallets WHERE id = $1 FOR UPDATE SKIP LOCKED",
            [wallet_id_bin]
          ).rows != []
        end)

      Enum.reduce(locked_wallet_ids, 0, fn wallet_id_bin, count ->
        holds =
          Repo.query!(
            """
            SELECT id, hold_mc
            FROM llm_wallet_holds
            WHERE wallet_id = $1
              AND status = 'active'
              AND expires_at <= $2
            FOR UPDATE
            """,
            [wallet_id_bin, now]
          ).rows

        Enum.each(holds, fn [hold_id_bin, hold_mc] ->
          Repo.query!("DELETE FROM llm_wallet_holds WHERE id = $1", [hold_id_bin])

          Repo.query!(
            """
            UPDATE llm_wallets
            SET held_mc = GREATEST(0, held_mc - $2), updated_at = $3
            WHERE id = $1
            """,
            [wallet_id_bin, hold_mc, now]
          )
        end)

        count + length(holds)
      end)
    end)

    :ok
  end
end
