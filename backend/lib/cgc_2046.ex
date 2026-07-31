defmodule Cgc2046 do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize? false
  end

  resources do
    # Resources are registered here as the domain model is agreed on.
    # Example:
    # resource Cgc2046.Resources.User
  end
end
