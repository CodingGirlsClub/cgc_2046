defmodule Cgc2046.Notifications.ScheduleChangedSubscriber do
  @moduledoc """
  Debounces event.schedule_changed signals (#565): instead of fanning out
  immediately (one blast per edit), each signal (re)schedules a single
  delayed fanout job per event. Content is rendered from the event state
  at delivery time (latest-wins) by the fanout worker.
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.schedule_changed"],
    idempotency: :claim_after_effects,
    consumer_key: "schedule_changed_subscriber"

  alias Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker

  # 分档静默窗（#565）：时间变更 5 分钟（参与者可能已在路上）；场地及其他
  # 15 分钟。窗口内后续编辑经 Oban replace 推迟同一条 job（合并为一轮）。
  @time_change_window_seconds 300
  @default_window_seconds 900

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle("event.schedule_changed", %{"event_id" => event_id} = data) do
    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(debounce_seconds(data), :second)

    case %{event_id: event_id}
         |> ScheduleChangedFanoutWorker.new(
           scheduled_at: scheduled_at,
           # 窗内后续编辑推迟同一条 job（unique 只锚 scheduled，见 worker
           # 模块）；旧 job 已离开 scheduled 时不匹配 unique → 新 job 独立
           # 插入，最终态必达优先于去重
           replace: [scheduled: [:scheduled_at]]
         )
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(_type, _data), do: :ok

  # 时间变更档：starts_at 出现在 changed 即按 5 分钟（时间敏感度最高）。
  defp debounce_seconds(%{"changed" => changed}) when is_list(changed) do
    if "starts_at" in changed,
      do: @time_change_window_seconds,
      else: @default_window_seconds
  end

  # 旧格式信号（无 changed 维度，#565 之前入队的信号）按保守默认档
  defp debounce_seconds(_data), do: @default_window_seconds
end
