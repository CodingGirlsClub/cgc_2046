defmodule Cgc2046.GlobalApi do
  @moduledoc """
  全局域(Global Api):承载**不按租户隔离**的全局资源 —— User、Identity、
  Token、Workspace(Workspace 本身是租户的根,但它属于全局资源)。

  T01 阶段仅接线,资源由后续票据注册:
  - T02 全局账号与认证:User / Identity / Token
  - T03 Workspace 与多租户地基:Workspace

  GraphQL 出口:`authorize? false` 仅为脚手架默认,严格授权链(T05)落地后
  改为真实授权判定。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(false)
  end

  resources do
    # 全局资源在此注册(按票据顺序):
    resource Cgc2046.Accounts.User
    resource Cgc2046.Accounts.Token
    # resource Cgc2046.Resources.Identity(待 OAuth 需求落地)
    # resource Cgc2046.Resources.Workspace
  end
end
