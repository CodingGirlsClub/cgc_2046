defmodule Cgc2046.Workers.NotificationWorker do
  @moduledoc "异步发送审批结果或提醒订阅消息。"

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    platform = String.to_existing_atom(args["platform"])

    case Cgc2046.NotificationService.send_to_user(
           args["user_id"],
           platform,
           args["template_key"],
           args["data"] || %{}
         ) do
      :ok -> :ok
      {:error, reason} when reason in [:consent_exhausted, :platform_identity_not_found] -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
