defmodule Cgc2046.LlmGateway.Workers.CreditExpiryReminderWorker do
  @moduledoc """
  每小时扫描即将在 72 小时内到期的活跃 LLM 额度批次，向用户写入站内通知
  （`llm_credit_expiring`），每笔批次全生命周期按 `llm_grant_expiring:<grant_id>`
  幂等只提醒一次。
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Cgc2046.Notifications.Inbox
  alias Cgc2046.Repo

  @reminder_window_seconds 72 * 3_600

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    horizon = DateTime.add(now, @reminder_window_seconds, :second)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, user_id, remaining_mc, expires_at
        FROM llm_credit_grants
        WHERE status = 'active'
          AND remaining_mc > 0
          AND expires_at IS NOT NULL
          AND expires_at > $1
          AND expires_at <= $2
        ORDER BY expires_at ASC, id ASC
        """,
        [now, horizon]
      )

    Enum.each(rows, fn [grant_id_bin, user_id_bin, remaining_mc, expires_at] ->
      grant_id = Ecto.UUID.load!(grant_id_bin)
      user_id = Ecto.UUID.load!(user_id_bin)

      data = %{
        "grant_id" => grant_id,
        "remaining_cny" => format_cny(remaining_mc),
        "expires_at" => expires_at |> to_utc_datetime() |> DateTime.to_iso8601()
      }

      meta = %{"idempotency_key" => "llm_grant_expiring:#{grant_id}"}

      try do
        Inbox.record(user_id, "llm_credit_expiring", data, meta)
      rescue
        error ->
          Logger.warning(
            "llm credit expiry reminder failed for grant_id=#{grant_id} user_id=#{user_id}: #{Exception.message(error)}"
          )
      end
    end)

    :ok
  end

  defp format_cny(mc) when is_integer(mc) and mc >= 0 do
    cents = div(mc, 10_000)
    yuan = div(cents, 100)
    rem_cents = rem(cents, 100)
    "#{yuan}.#{String.pad_leading(Integer.to_string(rem_cents), 2, "0")}"
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
end
