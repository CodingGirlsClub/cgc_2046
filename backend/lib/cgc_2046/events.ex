defmodule Cgc2046.Events do
  @moduledoc """
  活动域（ADR-0009 PR②）：Event / SpeakerInvitation 家族归 Events 限界上下文
  （长运营能力迭代重心）。Sponsorship 家族已随 PR④ 独立成 Cgc2046.Sponsorship。

  KTD1 域纪律：与 Cgc2046.Api / Cgc2046.Payments / Cgc2046.Admission 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止意外公开
  租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（同 Cgc2046.Api）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Events")
    resource_group_labels(events: "活动")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # ADR-0009 R3：Event / SpeakerInvitation 家族归 Events context
    resource(Cgc2046.Events.Event)
    resource(Cgc2046.Events.SpeakerInvitation)
  end
end
