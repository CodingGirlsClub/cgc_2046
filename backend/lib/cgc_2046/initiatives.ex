defmodule Cgc2046.Initiatives do
  @moduledoc """
  Initiative（倡导活动）领域：跨 Workspace 的活动身份与规则。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    show?(true)
    name("Initiatives")
    resource_group_labels(initiatives: "倡导活动")
  end

  graphql do
    authorize?(true)
  end

  resources do
    resource(Cgc2046.Initiatives.Initiative)
    resource(Cgc2046.Initiatives.InitiativeRule)
  end
end
