defmodule Cgc2046.Events.SpeakerSubscriber do
  @moduledoc """
  订阅 SpeakerInvitation 生命周期信号并为相关用户创建 Oban 通知任务（E-4 #49）。

  订阅的信号与通知对象（邀请设计 §4.2 订阅方表）：

  - speaker.accepted → 邀请所属 workspace 的 Owner/Admin（Speaker 已接受）
  - speaker.completed → Owner/Admin（分享完成）+ Speaker 本人（材料已归档）

  订阅骨架与 claim-first 幂等语义由 `Cgc2046.Workflows.SignalSubscriber` 统一
  持有（语义事实见其 moduledoc）；收件人解析与 Oban 入队收敛到
  `Cgc2046.Notifications.Fanout`（唯一实现，通知分发面深化 PR-C）——本模块退化为
  纯订阅方。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["speaker.accepted", "speaker.completed"],
    idempotency: :claim_first,
    consumer_key: "speaker_subscriber"

  require Logger

  alias Cgc2046.Offering

  @accepted_signal "speaker.accepted"
  @completed_signal "speaker.completed"

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(@accepted_signal, data), do: handle_accepted(data)
  def handle(@completed_signal, data), do: handle_completed(data)
  def handle(_type, _data), do: :ok

  defp handle_accepted(data) do
    case Map.get(data, "speaker_invitation_id") do
      id when is_binary(id) ->
        notify_workspace_managers(data, "speaker_accepted")

      _ ->
        :ok
    end
  end

  defp handle_completed(data) do
    case Map.get(data, "speaker_invitation_id") do
      id when is_binary(id) ->
        notify_workspace_managers(data, "speaker_completed")
        notify_speaker(data)

      _ ->
        :ok
    end
  end

  # 任务身份锚用生产者注入的幂等键（SignalEmitter 保证存在，骨架 claim 前置门控）。
  defp producer_key(data), do: Map.fetch!(data, "idempotency_key")

  # 通知 workspace Owner/Admin（管理角色判定唯一真源 `Role.manage_roles/0`，
  # 经 Notifications.Fanout.managers/2 收敛）
  defp notify_workspace_managers(data, template_key) do
    invitation_id = Map.fetch!(data, "speaker_invitation_id")

    job_meta = %{
      "speaker_invitation_id" => invitation_id,
      "idempotency_key" => producer_key(data)
    }

    with {:ok, title} <- event_title(data) do
      data
      |> Map.fetch!("workspace_id")
      |> Cgc2046.Notifications.Fanout.managers()
      |> Cgc2046.Notifications.Fanout.deliver(
        template_key,
        %{"speaker_invitation_id" => invitation_id, "title" => title},
        job_meta
      )
    else
      {:error, reason} ->
        Logger.warning("speaker notification skipped for #{invitation_id}: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("speaker manager notification failed: #{Exception.message(error)}")
      :ok
  end

  # 通知 Speaker 本人（材料已归档；speaker_user_id 在 accepted 时绑定）
  defp notify_speaker(data) do
    invitation_id = Map.get(data, "speaker_invitation_id")

    case Map.get(data, "speaker_user_id") do
      user_id when is_binary(user_id) ->
        Cgc2046.Notifications.Fanout.deliver(
          {user_id, Cgc2046.Notifications.Fanout.identities(user_id)},
          "speaker_completed",
          %{"speaker_invitation_id" => invitation_id},
          %{"speaker_invitation_id" => invitation_id, "idempotency_key" => producer_key(data)}
        )

      _ ->
        Logger.warning("speaker completed notification skipped: missing speaker_user_id")
    end

    :ok
  rescue
    error ->
      Logger.warning("speaker notification failed: #{Exception.message(error)}")
      :ok
  end

  # 标题解析唯一真源 = Offering 读取面（fetch_by_signal_payload 按 event_id 分派，
  # {:ok, nil}/未命中/错误统一坍缩 {:error, :not_found}——仅进日志无消费方；
  # 同 notifications.subscriber.target_title 形状，Offering 第六消费方）。
  defp event_title(data) do
    with {:ok, offering} <- Offering.fetch_by_signal_payload(data) do
      {:ok, Offering.title(offering)}
    end
  end
end
