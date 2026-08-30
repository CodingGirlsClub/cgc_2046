defmodule Cgc2046.Learning do
  @moduledoc """
  学习域（ADR-0009 PR⑤ U8 归位；S8 起为 ADR-0011 Learning v2）：
  Attempt（不可变评价账本，L1）+ Mastery/NextAction（派生投影纯函数族，
  L2/L5）+ Runs（run×revision 投影单源，L6）——账本挂人（attempts 永久
  保留、跨 run 可审计），掌握态挂 run × revision。

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
    # ADR-0011 L1（S8）：Attempt（不可变评价账本）取代 LearningRecord
    resource(Cgc2046.Learning.Attempt)
  end
end
