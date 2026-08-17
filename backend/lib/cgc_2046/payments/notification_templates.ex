defmodule Cgc2046.Payments.NotificationTemplates do
  @moduledoc """
  缴费闭环三通知模板（U10/KTD8/R22）。

  模板键、data/job_meta 键集与 unique 预设的**唯一真源** =
  `Cgc2046.Workers.NotificationWorker` 通知类型 registry（`type/1` / `types/0`；
  见 CONTEXT.md「通知类型（Notification Types）」词条）——本 module 不再重复
  声明键集契约（2026-08-18 架构深化候选 D，D6 单点化）。

  用途（R22，生产方视角）：

  - `payment_succeeded` —— 支付成功 → 报名人；
  - `refund_succeeded` —— 退款成功 → 报名人 + 发起管理员（单笔管理员退款经
    PaymentRefundWorker job args `initiator_user_id` 精确到发起人；自动退款 /
    Event cancelled 批量无发起人，收件人取 workspace 管理者超集）；
  - `refund_failed` —— 退款失败 → 同上两人。

  payload 值构建（构建点不收敛 D4）：`payment_data/1` 全 string 值（订阅消息
  渠道 data 值须为字符串）；金额以元展示、两位小数（R20 存储侧仍一律分）；
  幂等键在 job_meta `idempotency_key`（`<template_key>:<order_id>`），worker
  重入/崩溃重试补发天然去重。
  """

  @payment_succeeded "payment_succeeded"
  @refund_succeeded "refund_succeeded"
  @refund_failed "refund_failed"

  def payment_succeeded, do: @payment_succeeded
  def refund_succeeded, do: @refund_succeeded
  def refund_failed, do: @refund_failed

  @doc "三模板共用 data 负载（R22 契约见 moduledoc）。"
  @spec payment_data(Cgc2046.Payments.Order.t()) :: %{String.t() => String.t()}
  def payment_data(order) do
    %{
      "order_id" => order.id,
      "enrollment_id" => order.enrollment_id,
      "amount" => yuan(order.amount_cents),
      "provider" => to_string(order.provider)
    }
  end

  defp yuan(cents) when is_integer(cents) and cents >= 0,
    do: :erlang.float_to_binary(cents / 100, decimals: 2)
end
