defmodule Cgc2046.Accounts.User do
  @moduledoc """
  全局用户资源（ADR-0004 收窄为全局身份）。

  认证策略：
  - `password`（ash_authentication 内置）：`register_with_password` 注册 /
    `sign_in_with_password` 登录，签发 JWT（存于 metadata `:token`）。
    users.email/hashed_password 已放宽可空（Phase 1 小程序手机号用户无邮箱），
    但注册仍强制 email——由 register action 的 `require_attributes: [:email]` 策略层兜底。
  - `miniprogram`（自定义 `Cgc2046.Accounts.Strategies.Miniprogram`，Phase 1）：
    `sign_in_with_miniprogram` 一键登录——code2session → 平台手机号 → phone 锚定
    find-or-create → 挂 UserIdentity → 签发带 platform claim 的 JWT（TTL 7 天）。

  GraphQL 暴露（手写于 `Cgc2046Web.GraphqlSchema`，非 ash_authentication 自动生成；
  登录 token 经 httpOnly cookie 交付 #60 路径 B，响应体不含 token）：
  - mutation `signUp(input: {email, password})` → `SignUpPayload { result, errors }`（错误走 AshGraphql.Error 映射）
  - mutation `signIn(email:, password:)` → `SignInResult { id, email, isPlatformAdmin }`
  - mutation `signInWithPlatform(platform:, code:, encryptedData:, iv:)` → `SignInWithPlatformResult { id, email, isPlatformAdmin }`
  - query `me` → `User`（全局身份：id/email/displayName/isPlatformAdmin/memberNumber/joinedAt）

  phone 字段 `public?: false` + `sensitive?: true`：不进 GraphQL、不进日志 inspect
  （v1 明文存储已评审接受；掩码 + 本人可见的 GraphQL 暴露留给后续阶段）。

  ADR-0004：profile 字段（avatar_url/location/about/skills/visibility/ui_theme_preference）
  已迁至 `WorkspaceProfile`（per-workspace）；本资源仅保留全局身份字段。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshAuthentication,
      AshGraphql.Resource,
      AshAdmin.Resource,
      Cgc2046.Accounts.Strategies.Miniprogram
    ],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

    attribute(:email, :ci_string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "用户邮箱（全局唯一；小程序手机号用户为 null——Phase 1 起放宽可空）"
    )

    attribute(:hashed_password, :string,
      allow_nil?: true,
      sensitive?: true,
      public?: false,
      writable?: true,
      description: "密码哈希（不对外暴露，由 hash provider 写入；小程序用户为 null）"
    )

    attribute(:phone, :string,
      allow_nil?: true,
      public?: false,
      sensitive?: true,
      writable?: true,
      description: "手机号（小程序登录 User 锚，明文存储 v1 已评审接受；部分唯一索引 WHERE NOT NULL）"
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

    create :register_with_miniprogram do
      description(
        "小程序登录建号（仅 :miniprogram 策略经 ash_authentication 私有 context 内部调用；email 可空，phone 为锚）"
      )

      accept([:phone])
    end

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

    update :set_platform_admin do
      description("设置 is_platform_admin 标记（platform_admin 专用；CLI task 以 authorize?: false 调用）")
      require_atomic?(false)

      argument(:is_platform_admin, :boolean, allow_nil?: false)

      # writable?: false 阻止普通 change，需 force_change_attribute 绕过
      change(fn changeset, _context ->
        value = Ash.Changeset.get_argument(changeset, :is_platform_admin)
        Ash.Changeset.force_change_attribute(changeset, :is_platform_admin, value)
      end)
    end
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(Cgc2046.Accounts.Token)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)
      # Phase 1：JWT TTL 14d → 7d（research risk #5）；httpOnly cookie max_age 已对齐
      token_lifetime({7, :days})

      signing_secret(fn _, _ ->
        Application.fetch_env(:cgc_2046, :token_signing_secret)
      end)
    end

    strategies do
      password :password do
        identity_field(:email)
        confirmation_required?(false)
      end

      miniprogram do
        identity_resource(Cgc2046.Accounts.UserIdentity)
      end
    end
  end

  identities do
    identity(:unique_email, [:email])
    identity(:unique_phone, [:phone], where: expr(not is_nil(phone)))
  end

  postgres do
    table("users")
    repo(Cgc2046.Repo)

    # unique_phone 是部分唯一索引（phone IS NOT NULL 才参与）——snapshot/迁移生成器
    # 需要显式 SQL 谓词（与 20260808130100 迁移的 where 一致）。
    identity_wheres_to_sql(unique_phone: "phone IS NOT NULL")
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

    # 小程序登录入口同理（未认证调用；register_with_miniprogram 不在此列——
    # 它仅由策略内部经 ash_authentication 私有 context 调用，不能公开）。
    bypass action(:sign_in_with_miniprogram) do
      authorize_if(always())
    end

    # 用户读取：仅本人可读（ADR-0004 后 User 为全局身份，profile 可见性已迁
    # WorkspaceProfile.ReadWorkspaceProfileByVisibility；me 只查本人）。
    # 匿名（actor nil）→ filter 恒假不可读。
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.ReadOwnUser)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # 更新全局显示名：仅本人（SimpleCheck，strict 阶段可判定）
    policy action(:update_display_name) do
      authorize_if(Cgc2046.Policies.OwnUser)
    end

    # promote/demote：仅 platform_admin 可调用 set_platform_admin
    policy action(:set_platform_admin) do
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # 注意：不能使用 `policy always() do forbid_if(always()) end` 做默认拒绝。
    # Ash 表达式求解中，always condition 会使 `one_condition_matches` 恒真，
    # 从而把其它 normal policy 的授权要求从求解表达式中吸收掉（#68 已踩坑）。
    # 未匹配任何 policy 的动作天然被拒绝（与 workspace_membership 一致）。
  end

  graphql do
    type(:user)
  end

  admin do
    # Phase 6 / R12：AshAdmin 列表列裁剪 + sensitive 字段不显示。
    # phone/hashed_password 为 sensitive?: true，默认会被 ash_admin redact；
    # show_sensitive_fields([]) 显式声明不展示任何 sensitive 字段值（防泄露）。
    table_columns([:id, :email, :display_name, :is_platform_admin, :inserted_at])
    show_sensitive_fields([])
    # ash_admin actor impersonation：允许 platform_admin 以 User 为 actor 浏览
    # （门控在 :admin_browser pipeline 的 PlatformAdminPlug，actor 机制仅作调试用）
    actor?(true)
  end
end
