defmodule Cgc2046.GlobalApi do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(false)
  end

  resources do
    # Global resources (User / Workspace) are registered here as the domain model is agreed on.
    # (M0.1 项目接线: domain 就位, 资源自 M0.2 起逐个注册)
  end
end
