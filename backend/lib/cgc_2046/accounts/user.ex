defmodule Cgc2046.Accounts.User do
  @moduledoc """
  全局用户资源。

  使用 `ash_authentication` 的 Password 策略提供注册/登录：
  - `register_with_password`（create action）：注册，签发 JWT（存于 metadata `:token`）
  - `sign_in_with_password`（read action，get? true）：登录，校验密码后签发 JWT

  GraphQL 暴露：
  - mutation `signUp(input: {email, password})` → `SignUpResult { result, errors, metadata { token } }`
  - mutation `signIn(email:, password:)` → `SignInResult`（含 `token` metadata 字段）
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication, AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "用户邮箱（全局唯一，登录身份标识）"

    attribute :hashed_password, :string,
      allow_nil?: false,
      sensitive?: true,
      public?: false,
      writable?: true,
      description: "密码哈希（不对外暴露，由 hash provider 写入）"

    attribute :is_platform_admin, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: false,
      description: "是否平台管理员（全局标记）"

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "通过 JWT subject claim 获取用户"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end
  end

  authentication do
    tokens do
      enabled? true
      token_resource Cgc2046.Accounts.Token
      store_all_tokens? true
      require_token_presence_for_authentication? false
      signing_secret fn _, _ ->
        Application.fetch_env(:cgc_2046, :token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        confirmation_required? false
      end
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  postgres do
    table "users"
    repo Cgc2046.Repo
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end

  graphql do
    type :user

    queries do
      read_one :sign_in, :sign_in_with_password,
        as_mutation?: true,
        type_name: :sign_in_result,
        show_metadata: [:token],
        description: "使用邮箱密码登录，成功后返回用户及 JWT token"
    end

    mutations do
      create :sign_up, :register_with_password
    end
  end
end
