defmodule Cgc2046.Accounts.OAuthAuthorizationCode do
  @moduledoc """
  OAuth 2.1 授权码（短时、一次性消费；PKCE S256 挑战随码绑定）。

  由授权页审批（`/oauth/authorize`）经 `:create` 铸码、令牌端点经 `:consume`
  原子消费（`consumed_at` 置位，二次消费报 reuse）。码值即主键（随机 UUID），
  redirect_uri / scope / resource_uri / user_id 在铸码时绑定——令牌端点逐项回验
  （RFC 9700 §4.1：redirect_uri 精确匹配）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.Oauth2Server.AuthorizationCodeResource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:client_id, :uuid_v7,
      allow_nil?: false,
      public?: true,
      description: "OAuth client id"
    )

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "授权人（全局用户）ID"
    )

    attribute(:redirect_uri, :string,
      allow_nil?: false,
      public?: true,
      description: "铸码时绑定的回调地址（令牌端点精确回验）"
    )

    attribute(:code_challenge, :string,
      allow_nil?: false,
      public?: true,
      description: "PKCE S256 challenge"
    )

    attribute(:scope, :string,
      allow_nil?: false,
      public?: true,
      description: "授权 scope"
    )

    attribute(:resource_uri, :string,
      allow_nil?: false,
      public?: true,
      description: "授权受众（RFC 8707；= Oauth2Server.resource_url/0）"
    )

    attribute(:expires_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      description: "过期时间"
    )

    attribute(:consumed_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true,
      description: "消费时间（null = 未使用）"
    )
  end

  relationships do
    # 与其余用户域表一致的引用声明（除本组三张新表外，schema 里所有 user-scoped
    # 表都有 users FK）；define_attribute?: false——user_id 属性已在此手写声明。
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  postgres do
    table("oauth_authorization_codes")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :create do
      description("铸授权码（授权页审批后由 Authorize.issue_code!/4 调用）")

      accept([
        :client_id,
        :user_id,
        :redirect_uri,
        :code_challenge,
        :scope,
        :resource_uri,
        :expires_at
      ])
    end

    update :consume do
      description("一次性消费（原子置 consumed_at；已消费即报错）")
      accept([])

      validate(absent(:consumed_at), message: "code already used")
      change(atomic_update(:consumed_at, expr(now())))
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组（授权码（短时一次性；码值即主键））
    resource_group(:accounts)
  end
end
