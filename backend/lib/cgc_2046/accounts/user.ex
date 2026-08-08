defmodule Cgc2046.Accounts.User do
  @moduledoc """
  全局用户资源（ADR-0004 收窄为全局身份）。

  使用 `ash_authentication` 的 Password 策略提供注册/登录：
  - `register_with_password`（create action）：注册，签发 JWT（存于 metadata `:token`）
  - `sign_in_with_password`（read action，get? true）：登录，校验密码后签发 JWT

  GraphQL 暴露（手写于 `Cgc2046Web.GraphqlSchema`，非 ash_authentication 自动生成；
  登录 token 经 httpOnly cookie 交付 #60 路径 B，响应体不含 token）：
  - mutation `signUp(input: {email, password})` → `SignUpPayload { result, errors }`（错误走 AshGraphql.Error 映射）
  - mutation `signIn(email:, password:)` → `SignInResult { id, email, isPlatformAdmin }`
  - query `me` → `User`（全局身份：id/email/displayName/isPlatformAdmin/memberNumber/joinedAt）

  ADR-0004：profile 字段（avatar_url/location/about/skills/visibility/ui_theme_preference）
  已迁至 `WorkspaceProfile`（per-workspace）；本资源仅保留全局身份字段。
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
      description: "显示名（全局身份字段；可为 null，前端以 email 前缀兜底）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:workspace_memberships, Cgc2046.Accounts.WorkspaceMembership,
      destination_attribute: :user_id
    )
  end

  calculations do
    calculate(:member_number, :string, {Cgc2046.Accounts.Calculations.MemberNumber, []},
      public?: true,
      description: "平台级成员编号（P1 由用户 id 确定性生成，格式 CGC-XXXXXX，稳定唯一）"
    )

    calculate(:joined_at, :datetime, expr(inserted_at),
      public?: true,
      description: "注册（加入）时间"
    )
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

    update :update_display_name do
      description("更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段）")

      require_atomic?(false)

      accept([:display_name])

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

    # 用户读取：仅本人可读（ADR-0004 后 User 为全局身份，profile 可见性已迁
    # WorkspaceProfile.ReadWorkspaceProfileByVisibility；me 只查本人）。
    # 匿名（actor nil）→ filter 恒假不可读。
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.ReadOwnUser)
    end

    # 更新全局显示名：仅本人（SimpleCheck，strict 阶段可判定）
    policy action(:update_display_name) do
      authorize_if(Cgc2046.Policies.OwnUser)
    end

    # 注意：不能使用 `policy always() do forbid_if(always()) end` 做默认拒绝。
    # Ash 表达式求解中，always condition 会使 `one_condition_matches` 恒真，
    # 从而把其它 normal policy 的授权要求从求解表达式中吸收掉（#68 已踩坑）。
    # 未匹配任何 policy 的动作天然被拒绝（与 workspace_membership 一致）。
  end

  graphql do
    type(:user)
  end
end
