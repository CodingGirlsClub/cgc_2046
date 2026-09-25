defmodule Cgc2046.Notifications.Workers.DeliveryWorker do
  @moduledoc """
  NotificationDelivery 行的发送 worker。发送前经 `Staleness.stale?/1` 做过期
  重查（与 NotificationWorker 同一解释器，#847）；命中过期的行终态化
  `:failed`（`last_error` 为 `":stale"`）——复用既有状态值而非新增：status 是
  public 字段，扩值域会外溢到对账与前端（且新值不被规15 捞到，过期抑制反而
  失去对账面）；mark_failed 的终态语义（attempts 计数、rule 15 Finding 24h
  出报表）已满足「落终态可查」，且与 #556 末拍终态化同款先例
  （identity_not_found 也非发送失败仍落 :failed）。代价是规15 报表中过期抑制
  以「失败」面目出现，与真实发送失败靠 `last_error` 区分（`":stale"` vs
  inspect 出的结构化 reason）——过期与失败由此共用同一条既有对账通道，不为
  过期单开对账面。幂等防重发靠 Delivery.enqueue 的幂等键与 :sent 行 no-op。
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  alias Cgc2046.Notifications.{NotificationDelivery, Service, Staleness}

  @impl true
  def perform(%Oban.Job{args: %{"delivery_id" => id}} = job) do
    case Ash.get(NotificationDelivery, id, authorize?: false) do
      {:ok, %{status: :sent}} ->
        :ok

      {:ok, row} ->
        if Staleness.stale?(%{"template_key" => row.template_key, "data" => row.data}) do
          # 过期是确定性结论：终态化后 job 正常完成（不重试，NotificationWorker
          # 的 stale 分支同款 :ok）；对账信号在行的 last_error ":stale"。
          row
          |> Ash.Changeset.for_update(:mark_failed, %{last_error: inspect(:stale)},
            authorize?: false
          )
          |> Ash.update!()

          :ok
        else
          case deliver(row) do
            :ok ->
              :ok

            {:error, reason} ->
              # 末拍终态化（#556）：pending_reason 类失败此前只重试不落终态，
              # job 被 Oban 丢弃后行永留 pending、只能手工查表发现——末拍把
              # 仍 pending 的行落 :failed（带原因），由规15 Finding 出报表。
              # 已 :failed 行（非 pending 类失败首拍即落）不重复计数 attempts。
              if job.attempt >= job.max_attempts and row.status == :pending do
                terminalize(row, reason)
              end

              {:error, reason}
          end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # 终态化复用既有 :mark_failed（status → failed + attempts 计数 + last_error）
  defp terminalize(row, reason) do
    row
    |> Ash.Changeset.for_update(:mark_failed, %{last_error: inspect(reason)}, authorize?: false)
    |> Ash.update!()
  end

  # 哨兵行（Q5，语义见 Delivery moduledoc）：入队时零身份的行在此重解析——
  # 用户身份可能在其后已绑定；解析到首身份 assign 后投递，否则以
  # :identity_not_found 走重试→末拍终态化（pending_reason 类）。

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
