defmodule Cgc2046.Miniprogram do
  @moduledoc """
  Miniprogram domain（小程序渠道接入面；ADR-0010 ⑩ 方案 A 收缩 2026-08-29）。

  方案 A（资源跟写路径走）后仅剩 ShareScheme（微信 URL Scheme 分享链接缓存，
  全局资源，UK target+platform）——Code 随写方归 Accounts（InvitationCode /
  invitation_codes）、NotificationConsent 随写方归 Notifications
  （notification_consents）、LoginArtifactPrunerWorker 归 Accounts.Workers。

  无 GraphQL 面，仅经 /ops/admin 运营；故本 domain 不带 AshGraphql.Domain
  extension，也不进 graphql_schema domains 列表（与 Cgc2046.Mcp 同款）。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshAdmin.Domain]

  admin do
    # /ops/admin 可见性门控：:admin_browser pipeline 的 PlatformAdminPlug
    show?(true)

    name("Miniprogram")

    resource_group_labels(miniprogram: "小程序")
  end

  resources do
    # plan 011 P1：微信 URL Scheme 分享链接缓存（全局资源，UK target+platform）
    resource(Cgc2046.Miniprogram.ShareScheme)
  end
end
