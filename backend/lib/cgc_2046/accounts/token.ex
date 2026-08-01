defmodule Cgc2046.Accounts.Token do
  @moduledoc """
  登录 JWT 的存储资源（TokenResource）。

  由 `AshAuthentication.TokenResource` 自动生成属性/动作，用于 token 撤销、
  `store_all_tokens?` 时的全量 token 存储等。表中行由 ash_authentication 内部管理。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  postgres do
    table("tokens")
    repo(Cgc2046.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end
end
