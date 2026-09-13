defmodule Cgc2046.Notifications.Workers.DeliveryWorker do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  alias Cgc2046.Notifications.{NotificationDelivery, Service}

  @impl true
  def perform(%Oban.Job{args: %{"delivery_id" => id}}) do
    case Ash.get(NotificationDelivery, id, authorize?: false) do
      {:ok, %{status: :sent}} -> :ok
      {:ok, row} -> deliver(row)
      {:error, error} -> {:error, error}
    end
  end

  defp deliver(row) do
    if is_nil(row.identity_uid) or is_nil(row.platform) do
      case Cgc2046.Notifications.Fanout.identities(row.user_id) do
        [identity | _] ->
          with {:ok, assigned} <-
                 row
                 |> Ash.Changeset.for_update(
                   :assign_identity,
                   %{platform: to_string(identity.provider), identity_uid: identity.uid},
                   authorize?: false
                 )
                 |> Ash.update(),
               :ok <- deliver(assigned) do
            :ok
          end

        [] ->
          {:error, :identity_not_found}
      end
    else
      case Service.send_to_identity(
             row.user_id,
             String.to_existing_atom(row.platform),
             row.identity_uid,
             row.template_key,
             row.data
           ) do
        :ok ->
          case row
               |> Ash.Changeset.for_update(:mark_sent, %{}, authorize?: false)
               |> Ash.update() do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          if pending_reason?(reason) do
            {:error, reason}
          else
            row
            |> Ash.Changeset.for_update(:mark_failed, %{last_error: inspect(reason)},
              authorize?: false
            )
            |> Ash.update()

            {:error, inspect(reason)}
          end
      end
    end
  end

  defp pending_reason?(reason),
    do:
      reason in [
        :identity_not_found,
        :platform_identity_not_found,
        :template_not_configured,
        :consent_exhausted,
        :platform_not_configured
      ]
end
