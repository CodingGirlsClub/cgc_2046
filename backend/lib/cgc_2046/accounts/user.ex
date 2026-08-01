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
    uuid_primary_key(:id)

    attribute(:email, :ci_string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "用户邮箱（全局唯一，登录身份标识）"
    )

    attribute(:hashed_password, :string,
      allow_nil?: false,
      sensitive?: true,
      public?: false,
      writable?: true,
      description: "密码哈希（不对外暴露，由 hash provider 写入）"
    )

    attribute(:is_platform_admin, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: false,
      description: "是否平台管理员（全局标记）"
    )

    attribute(:display_name, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "显示名（#68 Profile API；可为 null，前端以 email 前缀兜底）"
    )

    attribute(:avatar_url, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "头像 URL（#68 Profile API，可选）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  validations do
    validate(match(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/),
      message: "must be a valid email address"
    )
  end

  actions do
    defaults([:read])

    read :get_by_subject do
      description("通过 JWT subject claim 获取用户")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    update :update_profile do
      description("更新当前用户个人资料（#68）：displayName（必填非空）+ avatarUrl（可选）")

      require_atomic?(false)

      accept([:display_name, :avatar_url])

      # 规范化：displayName 先 trim 再校验非空
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :display_name) do
          nil ->
            changeset

          name ->
            Ash.Changeset.change_attribute(changeset, :display_name, String.trim(name))
        end
      end)

      validate(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :display_name) do
          nil ->
            {:error, field: :display_name, message: "must not be blank"}

          name ->
            if String.trim(name) == "" do
              {:error, field: :display_name, message: "must not be blank"}
            else
              :ok
            end
        end
      end)
    end
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(Cgc2046.Accounts.Token)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)

      signing_secret(fn _, _ ->
        Application.fetch_env(:cgc_2046, :token_signing_secret)
      end)
    end

    strategies do
      password :password do
        identity_field(:email)
        confirmation_required?(false)
      end
    end
  end

  identities do
    identity(:unique_email, [:email])
  end

  postgres do
    table("users")
    repo(Cgc2046.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    # GraphQL 层调用 signUp/signIn 时不会设置 `ash_authentication?` context，
    # 需按 action 显式放行认证交互（register_with_password / sign_in_with_password）。
    bypass action(:register_with_password) do
      authorize_if(always())
    end

    bypass action(:sign_in_with_password) do
      authorize_if(always())
    end

    # #68：用户可更新自己的个人资料（SimpleCheck，strict 阶段可判定）
    policy action(:update_profile) do
      authorize_if(Cgc2046.Policies.UpdateOwnProfile)
    end

    # 用户只能读取自己（filter 阶段生效）
    policy action_type(:read) do
      authorize_if(expr(id == ^actor(:id)))
    end

    # 注意：不能使用 `policy always() do forbid_if(always()) end` 做默认拒绝。
    # Ash 表达式求解中，always condition 会使 `one_condition_matches` 恒真，
    # 从而把其它 normal policy 的授权要求从求解表达式中吸收掉（#68 已踩坑）。
    # 未匹配任何 policy 的动作天然被拒绝（与 workspace_membership 一致）。
  end

  graphql do
    type(:user)

    queries do
      read_one(:sign_in, :sign_in_with_password,
        as_mutation?: true,
        type_name: :sign_in_result,
        show_metadata: [:token],
        description: "使用邮箱密码登录，成功后返回用户及 JWT token"
      )
    end

    mutations do
      create :sign_up, :register_with_password
    end
  end
end
