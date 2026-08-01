defmodule Cgc2046.GlobalApi do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(true)
  end

  resources do
    # Global resources (User / Workspace) are registered here as the domain model is agreed on.
    resource(Cgc2046.Accounts.User)
    resource(Cgc2046.Accounts.Token)
    resource(Cgc2046.Accounts.Workspace)
    # Tenant-scoped resources (#64): isolated by workspace_id, policies enforced.
    resource(Cgc2046.Accounts.WorkspaceMembership)
    resource(Cgc2046.Accounts.MembershipRole)
    resource(Cgc2046.Accounts.Role)
  end
end
