defmodule Cgc2046.Reconciliation do
  @moduledoc """
  对账域（ADR-0009 PR⑤ U8，旧 Api domain 退役归位）：Reconciliation.Finding
  平台级孤儿报告底座（E-10 #125，/admin 对账页）。「底座共享 + 扫描器归各域」
  （定稿 §5.4 Platform Reporting）：Finding 存储 / 刷新语义 / admin 页共享，
  链路扫描（ReconciliationScanWorker）与资金对账扫描各归其域。

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
    name("Reconciliation")
    resource_group_labels(reconciliation: "对账")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # 对账扫描（E-10 #125：平台级孤儿报告，/admin 对账页）
    resource(Cgc2046.Reconciliation.Finding)
  end
end
