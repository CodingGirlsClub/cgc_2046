defmodule Cgc2046.Notifications.ScheduleChangedSubscriber do
  @moduledoc "Delivers durable schedule-change notifications from event signals."

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.schedule_changed"],
    idempotency: :claim_after_effects,
    consumer_key: "schedule_changed_subscriber"

  require Ash.Query

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle("event.schedule_changed", %{"event_id" => event_id} = data) do
    with {:ok, event} <- Ash.get(Event, event_id, authorize?: false),
         %Event{} = event <- event,
         {:ok, enrollments} <- active_enrollments(event) do
      Enum.each(enrollments, fn enrollment ->
        Cgc2046.Notifications.Delivery.enqueue(
          {enrollment.user_id, Cgc2046.Notifications.Fanout.identities(enrollment.user_id)},
          "event_schedule_changed",
          %{
            "event_id" => event.id,
            "title" => Map.get(data, "title", event.title),
            "starts_at" => Map.get(data, "starts_at", event.starts_at),
            "venue" => Map.get(data, "venue", event.venue)
          },
          %{"event_id" => event.id, "idempotency_key" => Map.fetch!(data, "idempotency_key")}
        )
      end)

      :ok
    else
      {:ok, nil} -> {:error, :event_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :event_not_found}
    end
  end

  def handle(_type, _data), do: :ok

  defp active_enrollments(event) do
    {:ok,
     Enrollment
     |> Ash.Query.filter(
       event_id == ^event.id and status in [:pending, :payment_pending, :confirmed]
     )
     |> Ash.read!(authorize?: false, tenant: event.workspace_id)}
  rescue
    error -> {:error, error}
  end
end
