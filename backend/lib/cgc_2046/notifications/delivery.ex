defmodule Cgc2046.Notifications.Delivery do
  @moduledoc """
  Durable, idempotent notification outbox.

  零身份语义（#847 Q5）：调用方解析不到任何平台身份时，不做 Fanout 式的
  「打日志后静默跳过」，而是落一行哨兵行（platform/identity_uid 均为 nil、
  status :pending）并入队——零身份由此成为可观测、可对账的记录：
  DeliveryWorker 发送前重解析身份（Fanout.identities/1），解析到则
  assign_identity 后投递（终态 :sent）；始终解析不到则以
  :identity_not_found 重试，末拍终态化 :failed（last_error 带原因，
  rule 15 Finding 24h 出报表）。「有身份但全部结构性无能力」（#1040 平台
  过滤，如 wechat_web）**不等于**零身份——入队即滤除，不落哨兵行。

  终态行不再重复入队（#1040 断复活闸）：幂等命中 :sent 或 :failed 行都
  不再插 DeliveryWorker job——瞬态错误的重试由 Oban 在同一 job 生命周期
  内承担（不走本函数），确定性终态由 DeliveryWorker 首拍落行；周期生产方
  的反复重唤由此不再复活必败 job。
  """
  alias Cgc2046.Notifications.{NotificationDelivery, Service, Workers.DeliveryWorker}

  def enqueue({user_id, identities}, template_key, data, job_meta) when is_list(identities) do
    key = Map.fetch!(job_meta, "idempotency_key")

    # #1040：结构性无订阅消息能力的平台身份（wechat_web 等）入队即滤除——
    # 投递必败，落行只会成为死信风暴原料；谓词唯一真源 =
    # Service.miniprogram_platform?/1。注意顺序：先判零身份（哨兵），再判
    # 「全部无能力」（跳过）——空列表 filter 后仍为空，两分支不可对调。
    capable = Enum.filter(identities, &Service.miniprogram_platform?(&1.provider))

    recipients =
      cond do
        identities == [] -> [%{provider: nil, uid: nil}]
        capable == [] -> []
        true -> capable
      end

    if recipients == [] do
      :ok
    else
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

               unless row.status in [:sent, :failed] do
                 %{delivery_id: row.id} |> DeliveryWorker.new() |> Oban.insert!()
               end
             end)
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "notification outbox failed: #{inspect(reason)}"
      end
    end
  end
end
