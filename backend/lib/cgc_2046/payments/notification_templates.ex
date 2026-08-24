defmodule Cgc2046.Payments.NotificationTemplates do
  @moduledoc """
  缴费闭环通知模板（U10/KTD8/R22 + organizer-payment U5/KTD6）。

  模板键、data/job_meta 键集与 unique 预设的**唯一真源** =
  `Cgc2046.Workers.NotificationWorker` 通知类型 registry（`type/1` / `types/0`；
  见 CONTEXT.md「通知类型（Notification Types）」词条）——本 module 不再重复
  声明键集契约（2026-08-18 架构深化候选 D，D6 单点化）。

  用途（R22 + organizer-payment R12/R13，生产方视角）：

  - `payment_succeeded` —— 支付成功 → 报名人；
  - `payment_received` —— 收款到账 → workspace 管理者逐笔实时收款感知
    （U5/R12；data 含活动名/档位名/金额）；
  - `payment_expired` —— 订单超时作废 → 报名人 + workspace 管理者（U5/R13；
    data 携带 re_enrollable 标志——报名截止未过才提示可重新报名）；
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
  @payment_received "payment_received"
  @payment_expired "payment_expired"
  @refund_succeeded "refund_succeeded"
  @refund_failed "refund_failed"

  def payment_succeeded, do: @payment_succeeded
  def payment_received, do: @payment_received
  def payment_expired, do: @payment_expired
  def refund_succeeded, do: @refund_succeeded
  def refund_failed, do: @refund_failed

  @doc "缴费模板共用 data 负载（R22 契约见 moduledoc）。"
  @spec payment_data(Cgc2046.Payments.Order.t()) :: %{String.t() => String.t()}
  def payment_data(order) do
    %{
      "order_id" => order.id,
      "enrollment_id" => order.enrollment_id,
      "amount" => yuan(order.amount_cents),
      "provider" => to_string(order.provider)
    }
  end

  @doc "组织者收款通知 data（U5/R12）：payment_data + 活动名 + 档位快照名。"
  @spec receipt_data(Cgc2046.Payments.Order.t(), String.t()) :: %{String.t() => String.t()}
  def receipt_data(order, title) do
    Map.merge(payment_data(order), %{
      "title" => title,
      "tier_name" => tier_name(order)
    })
  end

  @doc "订单超时通知 data（U5/R13）：payment_data + 活动名 + 可重报标志（string）。"
  @spec expiry_data(Cgc2046.Payments.Order.t(), String.t(), boolean()) :: %{
          String.t() => String.t()
        }
  def expiry_data(order, title, re_enrollable) do
    Map.merge(payment_data(order), %{
      "title" => title,
      "re_enrollable" => to_string(re_enrollable)
    })
  end

  defp tier_name(%{tier_snapshot: %{"name" => name}}) when is_binary(name), do: name
  defp tier_name(_), do: ""

  defp yuan(cents) when is_integer(cents) and cents >= 0,
    do: :erlang.float_to_binary(cents / 100, decimals: 2)
end
