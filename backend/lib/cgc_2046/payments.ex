defmodule Cgc2046.Payments do
  @moduledoc """
  支付域（plan feat/payment-loop）：座位保留型限时订单（Order）+ 渠道回调
  幂等去重（WebhookEvent）。

  KTD1 域纪律：与 Cgc2046.Api / Cgc2046.GlobalApi 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止未来
  注册到 GraphQL 面时意外公开租户资源。U1 尚无资源暴露 GraphQL/Admin
  （订单查询/操作面随 U5 落地）；WebhookEvent 为内部资源，永不暴露。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  graphql do
    authorize?(true)
  end

  resources do
    # 支付闭环 U1：微信/支付宝收单 + 在线全额退款（退款 = 取消报名，ADR-0007）
    resource(Cgc2046.Payments.Order)
    # 回调幂等去重（R21）：内部资源，无 GraphQL/Admin 暴露
    resource(Cgc2046.Payments.WebhookEvent)
  end
end
