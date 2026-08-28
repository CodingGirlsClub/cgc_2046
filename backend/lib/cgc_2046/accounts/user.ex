defmodule Cgc2046.Accounts.PasswordResetRevocationError do
  use Splode.Error, fields: [:reason], class: :unknown

  def message(_error), do: "password reset session revocation failed"
end

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
  - mutation `signIn(login:, password:)` → `SignInResult { id, email, isPlatformAdmin }`（login 含 @ 走 email，否则手机号归一化；plan 002 U2 起 email 入参改名 login）
  - mutation `signInWithPlatform(platform:, code:, phoneCode:, encryptedData:, iv:)` → `SignInWithPlatformResult { id, email, isPlatformAdmin }`（phoneCode 新契约优先，后两者 legacy 可空）
  - query `me` → `User`（全局身份：id/email/displayName/isPlatformAdmin/memberNumber/joinedAt）

  phone 字段 `sensitive?: true`；public 化是 password_phone 策略的 identity_field
  校验强制（见 attributes 块注释）——GraphQL 出口仍由手写 resolver 单点控制：
  User type 不含 phone，读仅经 myPhone 掩码查询（本人可见），写仅经
  updateMyPhone 换绑（v1 明文存储已评审接受）。

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
    domain: Cgc2046.Accounts

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

    # phone 需 public?: true —— password_phone 策略的 identity_field 校验强制
    # （ash_authentication transformer validate_identity_field/2）。GraphQL 出口
    # 已在 graphql 块 hide_fields([:phone]) 摘除（advisor02 M9）：User type 不含
    # phone，唯一读出口是手写 query myPhone（掩码，仅本人）；写出口是手写
    # mutation updateMyPhone（验证码验新号 → action :update_phone）。
    attribute(:phone, :string,
      allow_nil?: true,
      public?: true,
      sensitive?: true,
      writable?: true,
      description: "手机号（小程序/验证码/微信绑定登录的 User 锚，明文存储 v1 已评审接受；部分唯一索引 WHERE NOT NULL）"
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

    attribute(:locale, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "用户界面语言偏好（i18n Phase 1，BCP47 对外命名：zh-CN | en；null = 未设置，协商链回退）"
    )

    attribute(:onboarding_invitation_dismissed_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "首公里接入邀请的拒绝时间（R2：拒绝后模态不再自动弹出；null = 未拒绝，跨设备一致）"
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
    # 严格单邮箱（review MEDIUM，与 SpeakerInvitation.speaker_email 同形）：
    # 禁逗号/分号列表与控制字符，限 RFC 5321 长度——该值进入邮件投递面
    # （密码重置/邀请），旧形状 `[^\s@]+` 接受 "first,second@example.com"。
    validate(match(:email, ~r/^[^\s@,;"<>\\]+@[^\s@,;"<>\\]+\.[^\s@,;"<>\\]+$/),
      message: "must be a valid email address"
    )
  end

  # #116 R10a：治理留痕的 action/metadata 纯函数，供 LogAdminAction change 声明以
  # 远程捕获引用（DSL 实体 opts 需可转义：匿名 fn 与私有函数捕获都不可，须为 public
  # 且定义在 actions 之前）。
  @doc false
  def admin_log_action(changeset, _user) do
    if Ash.Changeset.get_argument(changeset, :is_platform_admin) do
      :admin_promote
    else
      :admin_demote
    end
  end

  @doc false
  def admin_log_user_metadata(_changeset, user), do: %{email: to_string(user.email)}

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

    update :update_phone do
      description("绑定/换绑当前用户手机号（仅本人；验证码校验在 GraphQL 层完成，占用唯一由 unique_phone 部分唯一索引兜底）")

      # 资源级改密吊销 change（KTD5，on: [:update]）使一切 update 无法原子校验，
      # 与 update_display_name 同置 false（单字段写入，无原子性需求）
      require_atomic?(false)

      accept([:phone])
    end

    update :update_locale do
      description("更新当前用户界面语言偏好（i18n Phase 1；zh-CN | en，仅本人）")

      require_atomic?(false)

      accept([:locale])

      validate(one_of(:locale, ["zh-CN", "en"]))
    end

    update :dismiss_onboarding_invitation do
      description("拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等——重复调用保留首次拒绝时间戳，仅本人）")

      require_atomic?(false)

      change(fn changeset, _context ->
        case changeset.data.onboarding_invitation_dismissed_at do
          nil ->
            Ash.Changeset.change_attribute(
              changeset,
              :onboarding_invitation_dismissed_at,
              DateTime.utc_now()
            )

          _already_dismissed ->
            changeset
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

      # #116 R10a：治理留痕 promote/demote（CLI 无 actor 调用时 actor_id 落 nil）；
      # 留痕失败上抛回滚本次变更（fail-closed）。action 由 argument 算出。
      change(
        {Cgc2046.Changes.LogAdminAction,
         action: &__MODULE__.admin_log_action/2,
         target_type: :user,
         metadata: &__MODULE__.admin_log_user_metadata/2}
      )
    end

    update :demote_platform_admin do
      description("降级平台管理员（≥1 admin 不变量唯一入口；原子条件 UPDATE 判定，并发双 demote 只有一个成功）")

      require_atomic?(false)

      # ≥1 admin 不变量：WHERE 子查询 count(platform_admin) > 1 下推成 DB 原子判定
      # （同 JoinRequest.approve 范式）；0 行命中 = 目标非 admin 或已是最后 admin。
      # 判定必须在 before_action 执行：change 在 for_update 阶段（授权前）运行，
      # 若在此直接写 DB 会"先写后授权"绕过 action policy；before_action 在授权后、
      # 事务内、Ash 写入前执行。成功路径 force_change_attribute 使 changeset 标记
      # 变更 → Ash 随后再写一次（幂等重复，无害），并让返回 record 反映新值。
      # 错误经 PlatformAdminError 携带 GraphQL code 契约。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          user = changeset.data

          if user.is_platform_admin do
            {:ok, res} =
              Ecto.Adapters.SQL.query(
                Cgc2046.Repo,
                """
                UPDATE users
                SET is_platform_admin = false
                WHERE id = $1 AND is_platform_admin = true
                  AND (SELECT count(*) FROM users WHERE is_platform_admin = true) > 1
                """,
                [Cgc2046.Repo.uuid!(user.id)]
              )

            if res.num_rows == 1 do
              Ash.Changeset.force_change_attribute(changeset, :is_platform_admin, false)
            else
              {:error,
               Cgc2046.Accounts.PlatformAdminError.exception(
                 code: "last_admin_denied",
                 message: "cannot demote the last remaining platform admin"
               )}
            end
          else
            {:error,
             Cgc2046.Accounts.PlatformAdminError.exception(
               code: "not_platform_admin",
               message: "user is not a platform admin"
             )}
          end
        end)
      end)

      # #116 R10a：治理留痕 demote（原子 UPDATE 成功后才进 after_action；
      # 失败上抛回滚，fail-closed）
      change(
        {Cgc2046.Changes.LogAdminAction,
         action: :admin_demote,
         target_type: :user,
         metadata: &__MODULE__.admin_log_user_metadata/2}
      )
    end
  end

  changes do
    # KTD5 偏差（RISK：见 writer03 report）：`log_out_everywhere` 的
    # `apply_on_password_change?` 依赖 where `Changing(hashed_password, touching?: true)`，
    # 而该条件在 changeset 构建期求值；自动生成的 `password_reset_with_password` 经
    # HashPasswordChange 的 before_action 才写入 hashed_password → 条件恒不满足，
    # 内置挂接在重置流程不触发；且其 bulk_update 缺 primary read action 直接抛错。
    # 此处以资源级 change 在重置 action 的 after_action 内直调同一生成 action
    # `revoke_all_stored_for_subject`（KTD5 指定的机制，非手写 revoke 循环），
    # 失败冒泡 → 改密事务整体回滚（fail-closed，同 KTD5 语义）。
    change(
      fn changeset, context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          try do
            subject = AshAuthentication.user_to_subject(record)

            Cgc2046.Accounts.Token
            |> Ash.Query.new()
            |> Ash.Query.set_context(%{private: %{ash_authentication?: true}})
            |> Ash.Query.for_read(:stored_for_subject, %{subject: subject})
            |> Ash.bulk_update(:revoke_all_stored_for_subject, %{subject: subject},
              strategy: [:atomic, :atomic_batches, :stream],
              context: %{private: %{ash_authentication?: true}},
              return_errors?: true,
              stop_on_error?: true,
              tenant: context.tenant
            )
            |> case do
              %{status: :success} ->
                {:ok, record}

              %{errors: errors} ->
                {:error, Cgc2046.Accounts.PasswordResetRevocationError.exception(reason: errors)}
            end
          rescue
            error ->
              {:error, Cgc2046.Accounts.PasswordResetRevocationError.exception(reason: error)}
          catch
            kind, reason ->
              {:error,
               Cgc2046.Accounts.PasswordResetRevocationError.exception(reason: {kind, reason})}
          end
        end)
      end,
      on: [:update],
      where: [{Ash.Resource.Validation.ActionIs, action: :password_reset_with_password}]
    )
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

        resettable do
          sender(Cgc2046.Accounts.SendPasswordResetEmail)
          token_lifetime({24, :hours})
        end
      end

      # 手机号 + 密码（plan 002 U2 登录；手机号注册）：与 email 策略共用
      # hashed_password。注册走 register_with_password_phone（GraphQL
      # signUpWithPhone：先验码后建号），email 可空（无邮箱手机号用户）。
      password :password_phone do
        identity_field(:phone)
        confirmation_required?(false)
        registration_enabled?(true)
      end

      miniprogram do
        identity_resource(Cgc2046.Accounts.UserIdentity)
      end
    end

    add_ons do
      log_out_everywhere do
        apply_on_password_change?(true)
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

    # 手机号密码登录/注册同理（plan 002 U2 / 手机号注册）。
    bypass action(:sign_in_with_password_phone) do
      authorize_if(always())
    end

    bypass action(:register_with_password_phone) do
      authorize_if(always())
    end

    bypass action(:request_password_reset_with_password) do
      authorize_if(always())
    end

    bypass action(:password_reset_with_password) do
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
      authorize_if(Cgc2046.Accounts.Policies.ReadOwnUser)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 更新全局显示名：仅本人（SimpleCheck，strict 阶段可判定）
    policy action(:update_display_name) do
      authorize_if(Cgc2046.Accounts.Policies.OwnUser)
    end

    # 绑定/换绑手机号：仅本人（验证码校验在 GraphQL resolver 完成）
    policy action(:update_phone) do
      authorize_if(Cgc2046.Accounts.Policies.OwnUser)
    end

    # 更新界面语言偏好：仅本人（i18n Phase 1）
    policy action(:update_locale) do
      authorize_if(Cgc2046.Accounts.Policies.OwnUser)
    end

    # 拒绝首公里接入邀请：仅本人（R2 拒绝状态持久化、跨设备一致）
    policy action(:dismiss_onboarding_invitation) do
      authorize_if(Cgc2046.Accounts.Policies.OwnUser)
    end

    # promote/demote：仅 platform_admin 可调用 set_platform_admin
    policy action(:set_platform_admin) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # demote 的 ≥1 admin 不变量由 action 自身守卫（原子条件 UPDATE）
    policy action(:demote_platform_admin) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 注意：不能使用 `policy always() do forbid_if(always()) end` 做默认拒绝。
    # Ash 表达式求解中，always condition 会使 `one_condition_matches` 恒真，
    # 从而把其它 normal policy 的授权要求从求解表达式中吸收掉（#68 已踩坑）。
    # 未匹配任何 policy 的动作天然被拒绝（与 workspace_membership 一致）。
  end

  graphql do
    type(:user)

    # advisor02 M9：password_phone 策略要求 phone public?: true，副作用是
    # ash_graphql 自动把它带进 type User——违反「不新增 phone 查询出口」。
    # 从 GraphQL 出口摘除（资源层仍 public 供策略校验）。
    hide_fields([:phone])
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
    # #113 ops 面优化：导航分组 + 关系下拉以 email 标识用户
    resource_group(:accounts)
    label_field(:email)
  end
end
