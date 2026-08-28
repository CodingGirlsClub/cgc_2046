defmodule Cgc2046.Sponsorship do
  @moduledoc """
  赞助域（ADR-0009 PR④）：两级赞助聚合（Sponsorship = Event 级单场 /
  Workspace 级长期）与履约账本（SponsorshipDelivery）。档位形状纯函数与结构校验上迁 Accounts
  （Cgc2046.Accounts.SponsorshipTier / SponsorshipTiersValidation,Fable 5 M6:
  tiers 属主在 Workspace/Event,本域下游消费）;event.ended 级联订阅器
  （SponsorshipEndedSubscriber）同目录。Event 侧保持软引用（D4/KD4：
  赞助不纯是 Event 的附属）。

  KTD1 域纪律：与 Cgc2046.Payments / Cgc2046.Admission /
  Cgc2046.Curriculum 同款——`graphql do authorize?(true) end`，未带 policy
  的动作默认拒绝，防止意外公开租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Sponsorship")
    resource_group_labels(sponsorship: "赞助")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # ADR-0009 D4/KD4：Sponsorship / SponsorshipDelivery 归 Sponsorship context
    resource(Cgc2046.Sponsorship.Sponsorship)
    resource(Cgc2046.Sponsorship.SponsorshipDelivery)
  end
end
