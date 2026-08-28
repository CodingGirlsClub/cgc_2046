defmodule Cgc2046.Learning do
  @moduledoc """
  学习域（ADR-0009 PR⑤ U8，旧 Api domain 退役归位）：LearningRecord 个人
  记忆库（切片 H U2，#180）——记忆挂人不挂报名（跨 enrollment 延续）；
  经读契约消费 Curriculum 已发布内容（定稿 §5.4）。

  KTD1 域纪律：与 Cgc2046.Payments / Cgc2046.Admission 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止意外公开
  租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Learning")
    resource_group_labels(learning: "学习")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # 学习记忆库（切片 H U2，#180）
    resource(Cgc2046.Learning.LearningRecord)
  end
end
