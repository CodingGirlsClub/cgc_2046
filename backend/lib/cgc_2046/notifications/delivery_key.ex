defmodule Cgc2046.Notifications.DeliveryKey do
  @moduledoc """
  耐久投递的事件键派生（#847 PR-B）——issue #847 映射表的代码面唯一真源。

  已迁键清单（`durable?/1`）与每键的事件键公式（`event_key/3`）在此单点
  维护；Fanout 委托层据此把 Delivery 幂等键定为
  `"{template_key}:{事件键}"`（P2 前缀，Delivery 侧再叠加 user×身份成分）。
  唯一保留直插的 flashback_wish_echo 不在本表（#834 回执契约，随后续 PR
  专门设计）。
  """

  # 事件键 = 生产方信号幂等键直用（emitter 规范 "<type>:<record_id>" 或支付侧
  # "<template>:<order_id>"），job_meta 已带。
  @from_meta_keys [
    "enrollment_submitted",
    "enrollment_completed",
    "enrollment_check_in_code",
    "speaker_accepted",
    "payment_succeeded",
    "payment_received",
    "payment_expired",
    "refund_succeeded",
    "refund_failed",
    "volunteer_application_submitted",
    "volunteer_application_interview",
    "volunteer_application_training",
    "volunteer_application_assigned",
    "volunteer_application_rejected",
    "volunteer_application_canceled"
  ]

  @durable_keys MapSet.new([
                  # 报名/审批类
                  "approval_result",
                  "enrollment_submitted",
                  "enrollment_completed",
                  "enrollment_check_in_code",
                  # 资金类
                  "payment_succeeded",
                  "payment_received",
                  "payment_expired",
                  "refund_succeeded",
                  "refund_failed",
                  # 提醒类
                  "approval_reminder",
                  "learning_stagnation",
                  # 其余键
                  "event_reminder",
                  "speaker_accepted",
                  "speaker_completed",
                  "event_moderator_assigned",
                  "event_moderator_removed",
                  "volunteer_application_submitted",
                  "volunteer_application_interview",
                  "volunteer_application_training",
                  "volunteer_application_assigned",
                  "volunteer_application_rejected",
                  "volunteer_application_canceled"
                ])

  @doc "已迁耐久投递的 template_key。"
  @spec durable?(String.t()) :: boolean()
  def durable?(template_key), do: MapSet.member?(@durable_keys, template_key)

  @doc """
  按映射表派生事件键。无派生公式的键（不在 @durable_keys）调用是编程错误，
  由 Fanout 的分派层保证不发生。
  """
  @spec event_key(String.t(), map(), map()) :: String.t()
  def event_key(template_key, data, job_meta)

  # 审批结论：同报名同结论去重；重审换结论（status 变化）重发（映射表：等价偏强）。
  def event_key("approval_result", data, _job_meta),
    do: "approval.result:#{data["enrollment_id"]}:#{data["status"]}"

  # approval_reminder 两面（enrollment/sponsorship）：deadline ≤48h < 7 天窗 ⇒
  # 生命周期内至多一次，永久幂等键直接去重（连行都不建）；Staleness 只兜发送
  # 时点已过期的残余窗口。
  def event_key("approval_reminder", _data, %{"enrollment_id" => id}),
    do: "approval.reminder:" <> id

  def event_key("approval_reminder", _data, %{"sponsorship_id" => id}),
    do: "approval.reminder:" <> id

  # learning_stagnation：周期成分 = epoch 对齐的 7 天桶（issue #847 裁定选项 a
  # ——静态幂等键无法表达 7 天滚动窗，周级桶窗业务可接受；桶边界周四 00:00
  # UTC，与 ISO 日历周等价的周级去重）。LPW 每 5 分钟扫，同桶多拍同键去重、
  # 跨桶新键重发。
  def event_key("learning_stagnation", _data, %{"run_id" => run_id}) do
    week_bucket = div(System.system_time(:second), 604_800)
    "learning.stagnation:#{run_id}:w#{week_bucket}"
  end

  # event_reminder：改期 → starts_at 变 → 新键重发（同现状语义）；event_id 由
  # event_reminder_worker 的 Fanout 调用处补入 job_meta（#847 已批例外）。
  def event_key("event_reminder", data, %{"event_id" => event_id}),
    do: "event.reminder:#{event_id}:#{data["starts_at"]}"

  def event_key("event_moderator_assigned", _data, %{"event_id" => event_id}),
    do: "event.moderator.assigned:#{event_id}"

  def event_key("event_moderator_removed", _data, %{"event_id" => event_id}),
    do: "event.moderator.removed:#{event_id}"

  # speaker_completed 双腿（P3）：manager 腿 data 带 title、speaker 本人腿不带
  # ——同 template 同信号键靠腿成分防撞（speaker 兼任 manager 的场景）。
  def event_key("speaker_completed", data, job_meta) do
    leg = if Map.has_key?(data, "title"), do: "managers", else: "speaker"
    "#{Map.fetch!(job_meta, "idempotency_key")}:#{leg}"
  end

  def event_key(template_key, _data, job_meta) when template_key in @from_meta_keys,
    do: Map.fetch!(job_meta, "idempotency_key")
end
