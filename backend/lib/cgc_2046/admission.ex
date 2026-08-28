defmodule Cgc2046.Admission do
  @moduledoc """
  报名域（ADR-0009 PR①）：Event/Course 的报名聚合（Enrollment）与邀请批次码
  （InviteBatch）。名额账本（CapacityLedger）随 PR⑤ U6 落地。

  KTD1 域纪律：与 Cgc2046.Api / Cgc2046.Payments 同款——
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
    name("Admission")
    resource_group_labels(admission: "报名")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # ADR-0009 KD1：Enrollment / InviteBatch 归 Admission context
    resource(Cgc2046.Admission.Enrollment)
    resource(Cgc2046.Admission.InviteBatch)
  end
end
