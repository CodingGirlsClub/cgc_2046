defmodule Cgc2046.Accounts.Token do
  @moduledoc """
  登录 JWT 的存储资源（TokenResource）。

  由 `AshAuthentication.TokenResource` 自动生成属性/动作，用于 token 撤销、
  `store_all_tokens?` 时的全量 token 存储等。表中行由 ash_authentication 内部管理。

  `:stored_for_subject` 是为 Phase 1 小程序策略重登吊销（按 subject 枚举活跃 token
  后逐个 `revoke_jti`）添加的内部读动作——仅 ash_authentication 私有 context 可达。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  require Ash.Query

  actions do
    read :stored_for_subject do
      description("内部：枚举某 subject 全部活跃（purpose=user）已存 token（重登吊销用）")

      argument(:subject, :string, allow_nil?: false, sensitive?: true)

      prepare(fn query, _context ->
        Ash.Query.filter(query,
          subject: Ash.Query.get_argument(query, :subject),
          purpose: "user"
        )
      end)
    end
  end

  postgres do
    table("tokens")
    repo(Cgc2046.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:accounts)
  end
end
