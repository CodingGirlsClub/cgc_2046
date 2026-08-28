defmodule Cgc2046.Api do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # Phase 6 / R12：AshAdmin /ops/admin 暴露该 Domain（安全门控由 :admin_browser pipeline
    # 的 PlatformAdminPlug 承担，不依赖 ash_admin actor 机制）
    show?(true)
    # #113 ops 面优化：domain 命名 + 资源分组标签
    name("Workflows & Events")
    resource_group_labels(workflows: "工作流")
  end

  graphql do
    # authorize?(true): matches GlobalApi. This domain has no resources yet;
    # setting true ensures any future resource registered here defaults to
    # Ash policy authorization (actions without a policy default to deny),
    # preventing accidental public exposure of tenant-scoped resources.
    authorize?(true)
  end

  resources do
    # Tenant-scoped resources are registered here as the domain model is agreed on.
    # (M0.1 项目接线: domain 就位, 资源自 M0.2 起逐个注册)

    # Slice C workflow 引擎（#34-#39，ADR-0002 Jido + ADR-0003 pi 重构）
    resource(Cgc2046.Workflows.WorkflowDefinition)
    resource(Cgc2046.Workflows.Step)
    resource(Cgc2046.Workflows.StepRole)
    resource(Cgc2046.Workflows.WorkflowRun)
    resource(Cgc2046.Workflows.SignalLog)
    resource(Cgc2046.Workflows.SignalIdempotency)

    # 学习记忆库(切片 H U2,#180)
    resource(Cgc2046.Learning.LearningRecord)

    # 对账扫描（E-10 #125：平台级孤儿报告，/admin 对账页）
    resource(Cgc2046.Reconciliation.Finding)
  end
end
