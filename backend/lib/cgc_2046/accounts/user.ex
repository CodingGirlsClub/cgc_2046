defmodule Cgc2046.Accounts.User do
  @moduledoc """
  全局账号(全局资源,不按租户隔离)。

  认证采用 ash_authentication Password 策略 + 白名单 token 模式:
  - `store_all_tokens? true`:平台签发的每个 JWT 都记录到 Token 资源
  - `require_token_presence_for_authentication? true`:请求认证时 token
    必须仍存在于 Token 资源(未撤销)才有效 —— 撤销即时全局失效
  - JWT 含 `jti` claim(`session_identifier` 语义),按 jti 定向撤销

  GraphQL 出口:`authorize? false` 仅为脚手架默认,严格授权链(T05)落地后
  改为真实授权判定(当前域级配置,见 `Cgc2046.GlobalApi`)。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string,
      allow_nil?: false,
      public?: true

    attribute :hashed_password, :string,
      allow_nil?: false,
      sensitive?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]
  end

  authentication do
    tokens do
      enabled? true
      token_resource Cgc2046.Accounts.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true

      signing_secret fn _, _ ->
        Application.fetch_env(:cgc_2046, :token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
      end
    end
  end

  postgres do
    table "users"
    repo Cgc2046.Repo
  end
end
