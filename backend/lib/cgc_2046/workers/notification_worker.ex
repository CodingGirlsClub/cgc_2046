defmodule Cgc2046.Workers.NotificationWorker do
  @moduledoc "异步发送审批结果或提醒订阅消息。"

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  alias Cgc2046.Events.Enrollment
  alias Cgc2046.NotificationService

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    platform = String.to_existing_atom(args["platform"])

    if stale_reminder?(args) do
      :ok
    else
      case deliver(args, platform) do
        :ok -> :ok
        {:error, reason} when reason in [:consent_exhausted, :platform_identity_not_found] -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # args 带 identity_uid 时按该身份精确投递（同用户同平台多身份不再互相覆盖）；
  # 否则回退到 user+platform 单身份解析。
  defp deliver(args, platform) do
    case args["identity_uid"] do
      uid when is_binary(uid) ->
        NotificationService.send_to_identity(
          args["user_id"],
          platform,
          uid,
          args["template_key"],
          args["data"] || %{}
        )

      _ ->
        NotificationService.send_to_user(
          args["user_id"],
          platform,
          args["template_key"],
          args["data"] || %{}
        )
    end
  end

  # 提醒发送时重查（扫描到执行之间，过期/审批可能已改变状态）：
  # 仅当报名仍 pending 且 deadline 未过时投递；其余情况静默跳过。
  defp stale_reminder?(%{
         "template_key" => "approval_reminder",
         "data" => %{"enrollment_id" => id}
       })
       when is_binary(id) do
    case Ash.get(Enrollment, id, authorize?: false) do
      {:ok, %{status: :pending, approval_deadline: nil}} ->
        false

      {:ok, %{status: :pending, approval_deadline: deadline}} ->
        DateTime.compare(deadline, DateTime.utc_now()) != :gt

      _ ->
        true
    end
  end

  defp stale_reminder?(_args), do: false
end
