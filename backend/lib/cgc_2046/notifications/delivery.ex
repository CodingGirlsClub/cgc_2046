defmodule Cgc2046.Notifications.Delivery do
  @moduledoc """
  Durable, idempotent notification outbox.

  零身份语义（#847 Q5）：调用方解析不到任何平台身份时，不做 Fanout 式的
  「打日志后静默跳过」，而是落一行哨兵行（platform/identity_uid 均为 nil、
  status :pending）并入队——零身份由此成为可观测、可对账的记录：
  DeliveryWorker 发送前重解析身份（Fanout.identities/1），解析到则
  assign_identity 后投递（终态 :sent）；始终解析不到则以
  :identity_not_found 重试，末拍终态化 :failed（last_error 带原因，
  rule 15 Finding 24h 出报表）。
  """
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
