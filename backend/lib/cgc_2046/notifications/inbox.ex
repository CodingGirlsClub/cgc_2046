defmodule Cgc2046.Notifications.Inbox do
  @moduledoc "站内接受记录与 30 天生命周期；不发送、不消费订阅配额。"
  require Ash.Query
  alias Cgc2046.Notifications.Notification

  def cutoff(now \\ DateTime.utc_now()), do: DateTime.add(now, -2_592_000, :second)

  def record(user_id, type, data, meta) do
    case Cgc2046.Notifications.InboxSnapshot.build(type, data, meta) do
      nil ->
        :ok

      snapshot ->
        source = source_key(type, data, meta)

        id =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({"notification-inbox-v1", user_id, type, source})
          )
          |> Base.encode16(case: :lower)

        existing =
          Notification
          |> Ash.Query.for_read(:retention)
          |> Ash.Query.filter(id == ^id)
          |> Ash.read_one!(authorize?: false)

        if is_nil(existing) do
          Notification
          |> Ash.Changeset.for_create(:record, %{},
            authorize?: false,
            actor: %{id: user_id},
            upsert?: true,
            upsert_fields: []
          )
          |> Ash.Changeset.force_change_attributes(
            Map.merge(snapshot, %{id: id, user_id: user_id, type: type})
          )
          |> Ash.create!()
        end

        :ok
    end
  end

  defp source_key("flashback_wish_echo", data, _meta),
    do: {Map.fetch!(data, "echo_id"), Map.fetch!(data, "wish_id")}

  defp source_key("speaker_completed", _data, meta) do
    key = Map.fetch!(meta, "idempotency_key")
    leg = Map.fetch!(meta, "leg")
    String.replace_suffix(key, ":" <> leg, "")
  end

  defp source_key(_type, _data, meta), do: Map.fetch!(meta, "idempotency_key")

  def purge(now \\ DateTime.utc_now()) do
    cutoff = cutoff(now)

    Notification
    |> Ash.Query.for_read(:retention)
    |> Ash.Query.filter(inserted_at <= ^cutoff)
    |> Ash.bulk_destroy!(:purge, %{},
      authorize?: false,
      read_action: :retention,
      strategy: [:atomic],
      return_errors?: true
    )

    :ok
  end
end
