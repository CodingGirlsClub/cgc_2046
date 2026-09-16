defmodule Cgc2046.Events.Qualification do
  @moduledoc """
  Deadline qualification primitive for Events.

  The event row is locked before taking the confirmed enrollment snapshot and
  the pending qualification status is a compare-and-set. Repeated scans
  therefore return `:skip` and cannot reverse an already recorded fact.
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event

  @spec qualify(Event.t()) ::
          {:ok, :confirmed | :underfilled, list(), non_neg_integer()} | :skip | :not_applicable
  def qualify(%Event{min_participants: nil}), do: :not_applicable

  def qualify(event) do
    case Cgc2046.Repo.transaction(fn ->
           case Cgc2046.Repo.query(
                  "SELECT qualification_status, status FROM events WHERE id = $1 FOR UPDATE",
                  [uuid_param(event.id)]
                ) do
             {:ok, %{rows: [["pending", "open"]]}} ->
               event = Ash.get!(Event, event.id, authorize?: false)

               if is_nil(event.min_participants) or is_nil(event.registration_deadline) or
                    DateTime.compare(event.registration_deadline, DateTime.utc_now()) != :lt do
                 :skip
               else
                 {:ok, %{rows: [[confirmed_count]]}} =
                   Cgc2046.Repo.query(
                     "SELECT COUNT(*) FROM enrollments WHERE event_id = $1 AND status = 'confirmed'",
                     [uuid_param(event.id)]
                   )

                 outcome =
                   if confirmed_count >= event.min_participants,
                     do: :confirmed,
                     else: :underfilled

                 {:ok, %{num_rows: 1}} =
                   Cgc2046.Repo.query(
                     "UPDATE events SET qualification_status = $1, updated_at = NOW() WHERE id = $2 AND qualification_status = 'pending' AND status = 'open'",
                     [to_string(outcome), uuid_param(event.id)]
                   )

                 recipients =
                   Enrollment
                   |> Ash.Query.filter(
                     event_id == ^event.id and status in [:pending, :payment_pending, :confirmed]
                   )
                   |> Ash.read!(authorize?: false, tenant: event.workspace_id)

                 enqueue_notifications(event, outcome, recipients, confirmed_count)

                 {:ok, outcome, recipients, confirmed_count}
               end

             _ ->
               :skip
           end
         end) do
      {:ok, {:ok, outcome, recipients, confirmed_count}} ->
        {:ok, outcome, recipients, confirmed_count}

      {:ok, :skip} ->
        :skip

      {:error, reason} ->
        Logger.warning("event qualification failed for #{event.id}: #{inspect(reason)}")
        :skip
    end
  end

  defp uuid_param(<<_::128>> = id), do: id
  defp uuid_param(id), do: Ecto.UUID.dump!(id)

  defp enqueue_notifications(event, outcome, enrollments, count) do
    template =
      if outcome == :confirmed,
        do: "event_qualification_confirmed",
        else: "event_qualification_underfilled"

    Enum.each(enrollments, fn enrollment ->
      Cgc2046.Notifications.Delivery.enqueue(
        {enrollment.user_id, Cgc2046.Notifications.Fanout.identities(enrollment.user_id)},
        template,
        %{
          "event_id" => event.id,
          "title" => event.title,
          "min_participants" => event.min_participants,
          "confirmed_count" => count
        },
        %{"event_id" => event.id, "idempotency_key" => "qualification:" <> event.id}
      )
    end)
  end
end
