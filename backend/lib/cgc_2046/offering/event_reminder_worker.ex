defmodule Cgc2046.Offering.EventReminderWorker do
  @moduledoc """
  活动开始提醒扫描（#203 方案 B）：starts_at 落在未来 24h 窗口的 open
  Event/Course → 向 confirmed 报名学员投递 event_reminder 订阅消息。

  本 worker 是发送侧最后一环，前置早已就绪：三平台模板 ID env（runtime.exs
  `*_MP_TEMPLATE_EVENT_REMINDER`）、NotificationWorker registry 契约
  （title/starts_at/venue）、Service 微信字段映射（thing2/time3/thing4）、
  小程序订阅触点（my-enrollments 页）。

  - starts_at 为 nil（时间待定）永不扫中（同 registration_deadline nil 语义）；
    过点后出窗——每活动至多在开始前 24h 窗口内提醒一轮。
  - 幂等：NotificationWorker :default 预设（7 天 args-unique 且 states: :all，
    args 含 user_id/identity_uid/template_key/data），cron 重扫/并发双拍/已发送
    完成的 job 均不重发；发送侧 Consent.take 按用户授权次数原子消费。
  - venue：Event 恰四键 map（Events.Venue），拼 city+district 紧凑串；
    Course 无 venue → 不传键（渲染层 drop_nils 跳过 thing4）。

  并发纪律同 EventLifecycleWorker：Oban 唯一任务（300s，与 cron 周期对齐）
  防并发双拍；单条投递失败由 Fanout rescue 内化（记 warning + telemetry），
  不中断整拍。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Notifications.Fanout

  @reminder_window_hours 24

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    window_end = DateTime.add(now, @reminder_window_hours, :hour)

    reminded =
      remind_starting(Event, :event, now, window_end) +
        remind_starting(Course, :course, now, window_end)

    if reminded > 0 do
      Logger.info("event reminder sweep: enqueued #{reminded} notification(s)")
    end

    :ok
  end

  defp remind_starting(resource, kind, now, window_end) do
    resource
    |> Ash.Query.filter(
      status == :open and not is_nil(starts_at) and starts_at > ^now and
        starts_at <= ^window_end
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn entity, acc -> acc + remind_confirmed(entity, kind) end)
  end

  # 计数按 enrollment（一活动一用户至多一报名）；实际入队数按 user×identity
  # 在 Fanout 内展开，此处为近似计数（日志用）。
  defp remind_confirmed(entity, kind) do
    entity
    |> confirmed_enrollments(kind)
    |> Enum.reduce(0, fn enrollment, acc ->
      user_id = enrollment.user_id

      Fanout.deliver(
        {user_id, Fanout.identities(user_id)},
        "event_reminder",
        reminder_data(entity),
        %{}
      )

      acc + 1
    end)
  end

  defp confirmed_enrollments(entity, :event) do
    Enrollment
    |> Ash.Query.filter(status == :confirmed and event_id == ^entity.id)
    |> Ash.read!(authorize?: false, tenant: entity.workspace_id)
  end

  defp confirmed_enrollments(entity, :course) do
    Enrollment
    |> Ash.Query.filter(status == :confirmed and course_id == ^entity.id)
    |> Ash.read!(authorize?: false, tenant: entity.workspace_id)
  end

  # data 值全字符串（订阅消息渠道契约，payment_data 同款纪律）；starts_at
  # ISO8601——Oban args JSON 化与 Service.time/1 的 binary 子句双兼容。
  defp reminder_data(%Event{starts_at: starts_at} = entity) do
    %{"title" => entity.title, "starts_at" => DateTime.to_iso8601(starts_at)}
    |> maybe_put_venue(entity)
  end

  defp reminder_data(entity) do
    %{"title" => entity.title, "starts_at" => DateTime.to_iso8601(entity.starts_at)}
  end

  defp maybe_put_venue(data, %Event{venue: venue}) when is_map(venue),
    do: Map.put(data, "venue", venue_text(venue))

  defp maybe_put_venue(data, _entity), do: data

  # thing ≤20 字由渲染层截断；city+district 中文直接拼接（恰四键已由
  # Events.Venue 校验，防御性 Map.get 兜 nil 剔除）
  defp venue_text(venue) do
    ["city", "district"]
    |> Enum.map(&venue[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end
end
