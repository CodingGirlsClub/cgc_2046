defmodule Cgc2046.NotificationSubscriber do
  @moduledoc "订阅 Enrollment 审批结果信号并为用户的各平台身份创建 Oban 通知任务。"

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workers.NotificationWorker

  @patterns ["enrollment.approved", "enrollment.rejected"]

  # 提醒任务的去重窗口：discarded/cancelled 释放名额（失败后下拍可重建），
  # completed/在途仍阻塞重复（#7）。
  @reminder_unique [
    period: 604_800,
    fields: [:worker, :args],
    states: [:scheduled, :available, :executing, :retryable, :completed]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Enum.each(@patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _subscription} -> :ok
        {:error, reason} -> Logger.warning("notification subscribe failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{}}
  end

  def enqueue_approval_result(%{"user_id" => user_id, "enrollment_id" => enrollment_id} = payload) do
    enqueue_for_identities(
      user_id,
      "approval_result",
      %{
        "status" => payload["status"] || "processed",
        "enrollment_id" => enrollment_id
      },
      %{"enrollment_id" => enrollment_id}
    )
  end

  def enqueue_reminder(user_id, enrollment_id, deadline) do
    user_id
    |> identities_for_user()
    |> enqueue_reminder_jobs(user_id, enrollment_id, deadline)
  rescue
    error ->
      Logger.warning("approval reminder enqueue failed: #{Exception.message(error)}")
      :ok
  end

  @doc "批量入口：调用方已预取该用户的平台身份（如按 workspace 一次读出）。"
  def enqueue_reminder_jobs(identities, user_id, enrollment_id, deadline) do
    Enum.each(identities, fn identity ->
      insert_notification(
        identity,
        user_id,
        "approval_reminder",
        %{
          "enrollment_id" => enrollment_id,
          "approval_deadline" => DateTime.to_iso8601(deadline)
        },
        %{"enrollment_id" => enrollment_id},
        @reminder_unique
      )
    end)

    :ok
  rescue
    error ->
      Logger.warning("approval reminder enqueue failed: #{Exception.message(error)}")
      :ok
  end

  defp enqueue_for_identities(user_id, template_key, data, job_meta) do
    user_id
    |> identities_for_user()
    |> Enum.each(&insert_notification(&1, user_id, template_key, data, job_meta, nil))

    :ok
  rescue
    error ->
      Logger.warning("approval notification enqueue failed: #{Exception.message(error)}")
      :ok
  end

  defp identities_for_user(user_id) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  # args 携带 identity_uid：同用户同平台多身份不再被 args-unique 折叠，
  # 发送侧按该身份精确投递（#3）。
  defp insert_notification(identity, user_id, template_key, data, job_meta, unique_override) do
    args =
      job_meta
      |> Map.merge(%{
        "user_id" => user_id,
        "identity_uid" => identity.uid,
        "platform" => to_string(identity.provider),
        "template_key" => template_key,
        "data" => data
      })

    case unique_override do
      nil -> NotificationWorker.new(args)
      unique -> NotificationWorker.new(args, unique: unique)
    end
    |> Oban.insert!()
  end

  defp handle_signal(signal) do
    signal
    |> Map.get(:data, %{})
    |> enqueue_approval_result()
  end
end
