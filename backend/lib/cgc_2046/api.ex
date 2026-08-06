defmodule Cgc2046.Api do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

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
  end
end
