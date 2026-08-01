defmodule Cgc2046.GlobalApi do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(false)
  end

  resources do
    # Global resources (User / Workspace) are registered here as the domain model is agreed on.
    resource(Cgc2046.Accounts.User)
    resource(Cgc2046.Accounts.Token)
  end
end
