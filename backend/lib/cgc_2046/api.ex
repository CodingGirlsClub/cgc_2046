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
  end
end
