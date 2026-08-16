defmodule Cgc2046.Payments.NotificationTemplates do
  @moduledoc """
  缴费闭环三通知模板契约定稿（U10/KTD8/R22）。

  模板键（config `:cgc_2046, :miniprogram_templates` 三平台 registry 已配，
  prod 模板 ID 经 runtime.exs 环境变量注入）：

  - `payment_succeeded` —— 支付成功 → 报名人（R22）；
  - `refund_succeeded` —— 退款成功 → 报名人 + 发起管理员（R22 精确归属见
    PaymentRefundWorker：单笔管理员退款经 job args `initiator_user_id` 精确到
    发起人；自动退款/Event cancelled 批量无发起人，收件人取 workspace 管理者
    超集）；
  - `refund_failed` —— 退款失败 → 同上两人。

  data 契约（全 string 值——订阅消息渠道 data 值须为字符串；金额以元展示，
  两位小数，R20 存储侧仍一律分）：

      order_id / enrollment_id / amount（"199.00"）/ provider

  unique 预设定稿：`:default`（NotificationWorker 自身 7 天全 args unique）；
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
