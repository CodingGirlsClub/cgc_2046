defmodule Cgc2046.Notifications.Workers.NotificationPrunerWorker do
  @moduledoc "每日删除已过 30 天的站内正文，不清理投递账本或订阅授权。"
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 86_400, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    :ok = Cgc2046.Notifications.Inbox.purge()
    Logger.info("notification inbox purge completed")
    :ok
  end
end
