defmodule Cgc2046.SpeakerSubscriber do
  @moduledoc """
  订阅 SpeakerInvitation 生命周期信号并为相关用户创建 Oban 通知任务（E-4 #49）。

  订阅的信号与通知对象（邀请设计 §4.2 订阅方表）：

  - speaker.accepted → 邀请所属 workspace 的 Owner/Admin（Speaker 已接受）
  - speaker.completed → Owner/Admin（分享完成）+ Speaker 本人（材料已归档）

  订阅骨架与 claim-first 幂等语义由 `Cgc2046.Workflows.SignalSubscriber` 统一
  持有（语义事实见其 moduledoc）；入队侧 NotificationWorker 7 天全 args
  unique，重复入队被折叠。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["speaker.accepted", "speaker.completed"],
    idempotency: :claim_first

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, UserIdentity, WorkspaceMembership}
  alias Cgc2046.Events.Event
  alias Cgc2046.Workers.NotificationWorker

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

  # 通知 workspace Owner/Admin（管理角色判定与 NotificationSubscriber 同款）
  defp notify_workspace_managers(data, template_key) do
    invitation_id = Map.fetch!(data, "speaker_invitation_id")

    job_meta = %{
      "speaker_invitation_id" => invitation_id,
      "idempotency_key" => producer_key(data)
    }

    with {:ok, title} <- event_title(data) do
      data
      |> Map.fetch!("workspace_id")
      |> managed_identities_by_user()
      |> Enum.each(fn {user_id, identities} ->
        Enum.each(identities, fn identity ->
          insert_notification(
            identity,
            user_id,
            template_key,
            %{"speaker_invitation_id" => invitation_id, "title" => title},
            job_meta
          )
        end)
      end)
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
        user_id
        |> identities_for_user()
        |> Enum.each(fn identity ->
          insert_notification(
            identity,
            user_id,
            "speaker_completed",
            %{"speaker_invitation_id" => invitation_id},
            %{"speaker_invitation_id" => invitation_id, "idempotency_key" => producer_key(data)}
          )
        end)

      _ ->
        Logger.warning("speaker completed notification skipped: missing speaker_user_id")
    end

    :ok
  rescue
    error ->
      Logger.warning("speaker notification failed: #{Exception.message(error)}")
      :ok
  end

  defp event_title(%{"event_id" => id}) when is_binary(id) and id != "" do
    case Ash.get(Event, id, authorize?: false) do
      {:ok, %Event{title: title}} -> {:ok, title}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_title(_data), do: {:error, :event_not_found}

  defp identities_for_user(user_id) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  # workspace Owner/Admin 的平台身份（按 user_id 分组；每工作台一次读取，
  # 与 NotificationSubscriber.managed_identities_by_user 同款实现）。
  defp managed_identities_by_user(workspace_id) do
    managed_ids =
      WorkspaceMembership
      |> Ash.Query.load(:roles)
      |> Ash.read!(tenant: workspace_id, authorize?: false)
      |> Enum.filter(fn membership ->
        membership.roles
        |> Enum.map(& &1.name)
        |> Enum.any?(&Role.manage_role?/1)
      end)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()

    case managed_ids do
      [] ->
        %{}

      managed_ids ->
        UserIdentity
        |> Ash.Query.filter(user_id in ^managed_ids)
        |> Ash.read!(authorize?: false)
        |> Enum.group_by(& &1.user_id)
    end
  end

  # args 携带 identity_uid：同用户同平台多身份不被 args-unique 折叠（#3）
  defp insert_notification(identity, user_id, template_key, data, job_meta) do
    args =
      job_meta
      |> Map.merge(%{
        "user_id" => user_id,
        "identity_uid" => identity.uid,
        "platform" => to_string(identity.provider),
        "template_key" => template_key,
        "data" => data
      })

    NotificationWorker.new(args) |> Oban.insert!()
  end
end
