defmodule Cgc2046.Notifications.Workers.ScheduleChangedFanoutWorker do
  @moduledoc """
  event.schedule_changed 的延迟 fanout（#565 debounce + latest-wins）。

  ScheduleChangedSubscriber 收到信号不立即全员投递，而是按分档窗口推迟本
  worker；窗口内的后续编辑经 Oban unique + replace 推迟同一条 job——连续
  编辑只发最终态一轮。执行时回查 event 真状态渲染（不使用编辑时刻的信号
  快照）；幂等键携带 Oban job id：同一 job 的重试不重发（Delivery upsert
  去重），新的编辑会话（新 job）则是新一轮通知。
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    # unique 只锚 scheduled（与 replace 分档对齐）：合并仅发生在 debounce 等待
    # 期——旧 job 一旦离开 scheduled（available/executing/retryable）就不挡新
    # 插入，那一刻又有编辑则新 job 必须建立（最终态必达优先于至多一条的重
    # 复，#565）。已完成 job 永不挡；retryable 旧 job 的重试与新增 job 至多
    # 双发一轮，方向无害。
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:scheduled]
    ]

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Event

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}, id: job_id}) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{} = event} ->
        fanout(
          event,
          "event.schedule_changed:" <> event_id <> ":fanout-" <> Integer.to_string(job_id)
        )

      # 活动已删：无需通知（改期对象不存在），静默成功（nil 与 NotFound 两种
      # 呈现都兜住——同原 subscriber 的 else 防御语义，#565）
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 投递时刻回查值渲染（latest-wins，#565）：title/starts_at/venue 全部取
  # fanout 执行时的 event 真状态，窗口内最后一次编辑的内容必然送达。
  defp fanout(event, idempotency_key) do
    event
    |> active_enrollments()
    |> Enum.each(fn enrollment ->
      Cgc2046.Notifications.Delivery.enqueue(
        {enrollment.user_id, Cgc2046.Notifications.Fanout.identities(enrollment.user_id)},
        "event_schedule_changed",
        %{
          "event_id" => event.id,
          "title" => event.title,
          "starts_at" => event.starts_at,
          "venue" => event.venue
        },
        %{"event_id" => event.id, "idempotency_key" => idempotency_key}
      )
    end)

    :ok
  end

  defp active_enrollments(event) do
    Enrollment
    |> Ash.Query.filter(
      event_id == ^event.id and status in [:pending, :payment_pending, :confirmed]
    )
    |> Ash.read!(authorize?: false, tenant: event.workspace_id)
  end
end
