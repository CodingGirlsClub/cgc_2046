defmodule Cgc2046.Notifications.Delivery do
  @moduledoc "Durable, idempotent notification outbox."
  alias Cgc2046.Notifications.{NotificationDelivery, Workers.DeliveryWorker}

  def enqueue({user_id, identities}, template_key, data, job_meta) when is_list(identities) do
    key = Map.fetch!(job_meta, "idempotency_key")
    recipients = if identities == [], do: [%{provider: nil, uid: nil}], else: identities

    case Cgc2046.Repo.transaction(fn ->
           Enum.each(recipients, fn identity ->
             idempotency_key =
               :crypto.hash(
                 :sha256,
                 :erlang.term_to_binary({key, user_id, identity.provider, identity.uid})
               )
               |> Base.encode16(case: :lower)

             row =
               NotificationDelivery
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   idempotency_key: idempotency_key,
                   user_id: user_id,
                   platform: if(identity.provider, do: to_string(identity.provider)),
                   identity_uid: identity.uid,
                   template_key: template_key,
                   data: data,
                   job_meta: job_meta
                 },
                 authorize?: false,
                 upsert?: true,
                 upsert_identity: :unique_delivery,
                 upsert_fields: []
               )
               |> Ash.create!()

             unless row.status == :sent do
               %{delivery_id: row.id} |> DeliveryWorker.new() |> Oban.insert!()
             end
           end)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "notification outbox failed: #{inspect(reason)}"
    end
  end
end
