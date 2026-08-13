defmodule Cgc2046.SpeakerSubscriber do
  @moduledoc """
  订阅 SpeakerInvitation 生命周期信号并为相关用户创建 Oban 通知任务（E-4 #49）。

  订阅的信号与通知对象（邀请设计 §4.2 订阅方表）：

  - speaker.accepted → 邀请所属 workspace 的 Owner/Admin（Speaker 已接受）
  - speaker.completed → Owner/Admin（分享完成）+ Speaker 本人（材料已归档）

  幂等（复用 PR #121 SignalIdempotency.claim/3，develop 已合入）：订阅方执行
  任何副作用前先 claim——accepted 按派生键 "speaker.accepted:<invitation_id>"，
  completed 优先取生产者携带的 idempotency_key（"speaker.completed:<id>"，
  邀请设计 §4.3）；同 (signal_type, idempotency_key) 已消费 → 跳过。入队侧
  NotificationWorker 7 天全 args unique，重复入队被折叠。
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, UserIdentity, WorkspaceMembership}
  alias Cgc2046.Events.Event
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency}
  alias Cgc2046.Workers.NotificationWorker

  @patterns ["speaker.accepted", "speaker.completed"]

  @accepted_signal "speaker.accepted"
  @completed_signal "speaker.completed"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Enum.each(@patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _subscription} -> :ok
        {:error, reason} -> Logger.warning("speaker subscribe failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{}}
  end

  @doc """
  信号总线回调：按 signal.type 分流到对应通知路径。

  回调运行在 JidoAdapter 转发的独立进程中（spawn_link），rescue 兜底防订阅
  进程崩溃。重复投递（同幂等键已 claim）返回 :duplicate 并跳过。
  """
  def handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case Map.get(signal, :type) do
      @accepted_signal -> handle_accepted(data)
      @completed_signal -> handle_completed(data)
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("speaker signal handling failed: #{Exception.message(error)}")
      :ok
  end

  # 副作用前幂等登记：首次 claim 返回 {:ok, key}；同 (signal_type, idempotency_key)
  # 已消费返回 :duplicate（调用方跳过）。key 优先取生产者携带的 idempotency_key
  # （completed），否则按 "<signal_type>:<invitation_id>" 派生（accepted）。
  defp claim(signal_type, data) do
    key =
      Map.get(data, "idempotency_key") ||
        "#{signal_type}:#{Map.get(data, "speaker_invitation_id")}"

    case SignalIdempotency.claim(signal_type, key, Map.get(data, "workspace_id")) do
      :ok -> {:ok, key}
      {:error, :already_claimed} -> :duplicate
    end
  end

  defp handle_accepted(data) do
    case Map.get(data, "speaker_invitation_id") do
      id when is_binary(id) ->
        with {:ok, key} <- claim(@accepted_signal, data) do
          notify_workspace_managers(data, "speaker_accepted", key)
        end

      _ ->
        :ok
    end
  end

  defp handle_completed(data) do
    case Map.get(data, "speaker_invitation_id") do
      id when is_binary(id) ->
        with {:ok, key} <- claim(@completed_signal, data) do
          notify_workspace_managers(data, "speaker_completed", key)
          notify_speaker(data, key)
        end

      _ ->
        :ok
    end
  end

  # 通知 workspace Owner/Admin（管理角色判定与 NotificationSubscriber 同款）
  defp notify_workspace_managers(data, template_key, key) do
    invitation_id = Map.fetch!(data, "speaker_invitation_id")
    job_meta = %{"speaker_invitation_id" => invitation_id, "idempotency_key" => key}

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
  defp notify_speaker(data, key) do
    invitation_id = Map.fetch!(data, "speaker_invitation_id")

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
            %{"speaker_invitation_id" => invitation_id, "idempotency_key" => key}
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
