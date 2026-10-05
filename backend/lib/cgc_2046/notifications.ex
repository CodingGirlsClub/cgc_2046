defmodule Cgc2046.Notifications do
  @moduledoc """
  Notifications domain（通知投递 + 订阅授权余额；ADR-0010 ⑩ 方案 A 新建，
  2026-08-29）。

  此前本 context 只有服务模块（Service/Fanout/Subscriber/Consent，无 Ash
  domain）；方案 A「资源跟写路径走」把订阅授权余额资源自 Miniprogram 迁回
  与唯一写方 `Cgc2046.Notifications.Consent`（裸 SQL grant/take/refund）同域，
  本 domain 模块自此必须存在。

  用户 GraphQL 面仅暴露 Notification 收件箱；Delivery/Consent 保持内部资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshAdmin.Domain, AshGraphql.Domain]

  admin do
    show?(true)

    show_resources([
      Cgc2046.Notifications.NotificationConsent,
      Cgc2046.Notifications.NotificationDelivery
    ])

    name("Notifications")

    resource_group_labels(notifications: "通知")
  end

  resources do
    # 订阅消息一次性授权余额（wechat/tt/xhs 三平台；写路径 = Consent 裸 SQL）
    resource(Cgc2046.Notifications.NotificationConsent)
    resource(Cgc2046.Notifications.NotificationDelivery)
    resource(Cgc2046.Notifications.Notification)
  end
end
