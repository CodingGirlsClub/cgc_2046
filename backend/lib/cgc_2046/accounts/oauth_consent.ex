defmodule Cgc2046.Accounts.OAuthConsent do
  @moduledoc """
  OAuth 授权同意记录（(user, client) 一行，`scope` 为已同意范围）。

  库在每次授权请求时回查 `Authorize.consented?/5`：已有同意的 scope 覆盖本次
  请求即直接发码（不再展示授权页），否则渲染授权页由用户确认——因此本表是
  「一次同意、长期复用」的载体，也是 scope 扩张时的再确认闸门（库只认超集）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "授权人（全局用户）ID"
    )

    attribute(:client_id, :uuid_v7,
      allow_nil?: false,
      public?: true,
      description: "OAuth client id"
    )

    attribute(:scope, :string,
      allow_nil?: false,
      public?: true,
      description: "已同意的 scope 串（覆盖判定按超集）"
    )

    attribute(:granted_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      description: "最近一次同意时间"
    )
  end

  relationships do
    # 与其余用户域表一致的引用声明（除本组三张新表外，schema 里所有 user-scoped
    # 表都有 users FK）；define_attribute?: false——user_id 属性已在此手写声明。
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  identities do
    identity(:by_user_client, [:user_id, :client_id])
  end

  postgres do
    table("oauth_consents")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :grant do
      description("记录/刷新同意（(user, client) 幂等 upsert）")
      accept([:user_id, :client_id, :scope])

      upsert?(true)
      upsert_identity(:by_user_client)
      change(set_attribute(:granted_at, &DateTime.utc_now/0))
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组（授权同意记录（(user, client) 一行））
    resource_group(:accounts)
  end
end
