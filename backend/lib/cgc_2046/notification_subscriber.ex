defmodule Cgc2046.NotificationSubscriber do
  @moduledoc "订阅 Enrollment 审批结果信号并为用户的各平台身份创建 Oban 通知任务。"

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.UserIdentity
  alias Cgc2046.Workflows.JidoAdapter
  alias Cgc2046.Workers.NotificationWorker

  @patterns ["enrollment.approved", "enrollment.rejected"]

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

  def enqueue_reminder(user_id, deadline) do
    enqueue_for_identities(user_id, "approval_reminder", %{
      "approval_deadline" => DateTime.to_iso8601(deadline)
    })
  end

  defp enqueue_for_identities(user_id, template_key, data, job_meta \\ %{}) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn identity ->
      job_meta
      |> Map.merge(%{
        "user_id" => user_id,
        "platform" => to_string(identity.provider),
        "template_key" => template_key,
        "data" => data
      })
      |> NotificationWorker.new()
      |> Oban.insert!()
    end)

    :ok
  rescue
    error ->
      Logger.warning("approval notification enqueue failed: #{Exception.message(error)}")
      :ok
  end

  defp handle_signal(signal) do
    signal
    |> Map.get(:data, %{})
    |> enqueue_approval_result()
  end
end
