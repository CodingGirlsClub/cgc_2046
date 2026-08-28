defmodule Cgc2046.Miniprogram do
  @moduledoc """
  Miniprogram domain(小程序运营资源;自 GlobalApi 拆出,plan
  docs/plans/2026-08-28-1900-refactor-accounts-miniprogram-domain-plan.md)。

  三资源(Code 登录码 / NotificationConsent 订阅授权 / ShareScheme 分享链接缓存)
  均无 GraphQL 面,仅经 /ops/admin 运营;故本 domain 不带 AshGraphql.Domain
  extension,也不进 graphql_schema domains 列表(与 Cgc2046.Mcp 同款)。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshAdmin.Domain]

  admin do
    # /ops/admin 可见性承接原 GlobalApi 的 miniprogram 组(安全门控同为
    # :admin_browser pipeline 的 PlatformAdminPlug)
    show?(true)

    name("Miniprogram")

    resource_group_labels(miniprogram: "小程序")
  end

  resources do
    resource(Cgc2046.Miniprogram.Code)
    resource(Cgc2046.Miniprogram.NotificationConsent)
    # plan 011 P1:微信 URL Scheme 分享链接缓存(全局资源,UK target+platform)
    resource(Cgc2046.Miniprogram.ShareScheme)
  end
end
