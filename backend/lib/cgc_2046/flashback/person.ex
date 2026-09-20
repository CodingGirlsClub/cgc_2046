defmodule Cgc2046.Flashback.Person do
  @moduledoc """
  校友档案：一位当年的报名者（学员/教练/志愿者/未入选者，R2 分流依据）。

  ## PII 边界（KTD3 /《个人信息处理规则》）

  `phone` / `email` 为触达与找回（R21/R23）的必要明文，**不进任何投影与日志**：
  本资源无 GraphQL 查询面，读出口只有两条——服务端 `authorize?: false` 内部路径
  （token 流、找回匹配）与 admin 面（运营）；一切对外投影（路人层/校友层/导出）
  由白名单 DTO 显式列字段，测试断言手机/邮箱零出现。

  ## public_slug（R32/R33，ADR-0014 成套契约）

  实名支持（`quote_license.level = :credited`）发布时占用公开档案页 slug：
  全局唯一（`flashback_slug_taken`），`public_slug_published_at` 置位即锁定
  （`flashback_slug_locked`，无 rename 后门——恢复路径 = 新建）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @roles [:learner, :coach, :volunteer]
  @participations [:attended, :not_selected]

  attributes do
    uuid_primary_key(:id)

    attribute(:archive_event_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    attribute(:full_name, :string, allow_nil?: false, public?: true, writable?: true)

    # 姓（单独字段）：墙与名册渲染「王**」的姓氏来源（R12 隐名不隐姓），
    # 导入期从 full_name 提取。
    attribute(:surname, :string, public?: true, writable?: true)
    attribute(:city, :string, public?: true, writable?: true)
    attribute(:occupation_then, :string, public?: true, writable?: true)
    attribute(:gender, :string, public?: true, writable?: true)

    # 敏感：明文触达通道，仅导入/找回/外发 worker 写读；不出任何投影（KTD3）。
    attribute(:phone, :string, public?: true, writable?: true)
    attribute(:email, :string, public?: true, writable?: true)

    attribute(:role, :atom,
      allow_nil?: false,
      default: :learner,
      public?: true,
      writable?: true,
      constraints: [one_of: @roles]
    )

    attribute(:participation, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @participations]
    )

    # 报名时间戳（ISO8601 原值，R3 相对年数的锚点）；个别行缺失时前端回落
    # 「当年的你」文案（AE1）。
    attribute(:applied_at, :utc_datetime_usec, public?: true, writable?: true)

    # 注册绑定（R27）：她注册的那一刻账号接管档案；nil = 仍走链接。
    attribute(:user_id, :uuid, public?: true, writable?: false)

    attribute(:public_slug, :string, public?: true, writable?: true)
    attribute(:public_slug_published_at, :utc_datetime_usec, public?: true, writable?: false)

    # 卡片分享链接标识（#771）：服务端铸的 24 字节随机十六进制串（48 字符），
    # 一旦铸出即**不可变**——关闭只清 `card_share_enabled_at`，重开复用同 id
    # （已投出的链接不因开关而换号）。public?: false：它是能力凭据（知道即能读
    # 那张分享卡），与 public_slug 的「公开档案页地址」不同，不进任何自动面；
    # 读出口只有显式白名单投影（SharedCard）。
    attribute(:card_share_slug, :string, public?: false, writable?: false)

    # 分享开关（#771）：置位 = 公开分享链接可解析；清空 = 关闭（slug 保留）。
    # 与 public_slug 发布锁、quote_license 授权档**无依赖**——分享独立成立。
    attribute(:card_share_enabled_at, :utc_datetime_usec, public?: true, writable?: false)
    # 触达退订（U8/R30，KTD6 按人抑制双通道）：置位后任何批次、任何通道
    # （email/sms）不再入队。真源在 person 行而非 outreach 行——首封邮件点击
    # 退订时尚无发送行。
    attribute(:outreach_unsubscribed_at, :utc_datetime_usec, public?: true, writable?: false)

    # 档案删除（U10/R30/ADR-0015）：置位 = 名册/统计/找回全面排除 + token
    # 全作废 + 个人字段匿名化（Outreach.Dispatch.anonymize_person/1）。行
    # 保留以承接 outreach 聚合分母（KTD10），个人内容（答案/回信/附议/授权）
    # 全部硬删。
    attribute(:deleted_at, :utc_datetime_usec, public?: true, writable?: false)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:archive_event, Cgc2046.Flashback.EventArchive,
      source_attribute: :archive_event_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    has_many(:answers, Cgc2046.Flashback.Answer, destination_attribute: :person_id)
    has_many(:tokens, Cgc2046.Flashback.Token, destination_attribute: :person_id)
    has_many(:touches, Cgc2046.Flashback.Touch, destination_attribute: :person_id)
    has_one(:today, Cgc2046.Flashback.Today, destination_attribute: :person_id)
    has_one(:quote_license, Cgc2046.Flashback.QuoteLicense, destination_attribute: :person_id)
  end

  identities do
    identity(:unique_public_slug, [:public_slug])

    # 分享链接标识全局唯一（#771）：服务端铸 48 字符 hex，唯一索引是最后防线
    # （撞了重铸，见 CardSharing）。
    identity(:unique_card_share_slug, [:card_share_slug])
  end

  postgres do
    table("flashback_people")
    repo(Cgc2046.Repo)
  end

  validations do
    validate(match(:public_slug, ~r/^[a-z0-9][a-z0-9-]*$/), only_when_valid?: true)
  end

  actions do
    defaults([:read])

    # 导入脚本专用（authorize?: false 路径）。
    create :create do
      accept([
        :archive_event_id,
        :full_name,
        :surname,
        :city,
        :occupation_then,
        :gender,
        :phone,
        :email,
        :role,
        :participation,
        :applied_at
      ])
    end

    # 服务端内部更新面（U2 绑定/联系方式、U6 发布 slug）；slug 锁定与撞名
    # 契约在此钉住（发布 = public_slug_published_at 置位，U6 落地）。
    update :update do
      require_atomic?(false)
      accept([:public_slug])

      # 发布后锁定（ADR-0014：公开 URL 段发布即契约）。同值回传不算变更
      # （Ash 在值相等时会从 attributes 移除该键，同 initiative #588 先例）。
      change(fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :public_slug) and
             not is_nil(Ash.Changeset.get_data(changeset, :public_slug_published_at)) do
          Ash.Changeset.add_error(
            changeset,
            Cgc2046.Errors.BusinessError.exception(
              message: "public slug is locked once published (choose a new one or keep it)",
              code: "flashback_slug_locked",
              fields: [:public_slug]
            )
          )
        else
          changeset
        end
      end)

      # 撞 slug 的唯一索引冲突转稳定业务错误（范式同 initiative #604）。
      error_handler({__MODULE__, :handle_write_error, []})
    end

    # 导入去重时的 participation 升级专用面：仅接受 attendance 状态变更，
    # 入口只有 Import.persist（录取名单修正场景：已有 not_selected、新行
    # attended → 升级）。GraphQL 不直连本 action。
    update :set_participation do
      require_atomic?(false)
      accept([:participation])
    end

    # 卡片分享开关（#771）专用内部面：入口只有 CardSharing 服务（它先解析
    # token/账号身份，再把服务端确认的 person_id 传进来），GraphQL 不直连本
    # action。`card_share_slug` / `card_share_enabled_at` 皆不在 accept 列表——
    # 标识由本 action **服务端铸出**（客户端无注入面），开关只动 enabled_at。
    update :set_card_sharing do
      require_atomic?(false)
      argument(:enabled, :boolean, allow_nil?: false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          enabled = Ash.Changeset.get_argument(cs, :enabled)
          existing_slug = Ash.Changeset.get_data(cs, :card_share_slug)

          cs =
            if enabled and is_nil(existing_slug) do
              # 首开才铸；已铸出的值**永不改写**（关闭只清 enabled_at，重开复用同 id）
              Ash.Changeset.force_change_attribute(
                cs,
                :card_share_slug,
                mint_card_share_slug()
              )
            else
              cs
            end

          Ash.Changeset.force_change_attribute(
            cs,
            :card_share_enabled_at,
            if(enabled, do: DateTime.utc_now())
          )
        end)
      end)

      error_handler({__MODULE__, :handle_write_error, []})
    end
  end

  # 分享标识：24 字节 CSPRNG → 48 字符小写 hex（URL 段安全字符集，无需转义）。
  @doc false
  def mint_card_share_slug do
    :crypto.strong_rand_bytes(24) |> Base.encode16(case: :lower)
  end

  # create/update error_handler：**按约束名分派**（范式同 Course #619 /
  # InitiativeRule #611）。本资源现有两个 identity：
  #   - unique_public_slug → flashback_people_unique_public_slug_index（既有契约）
  #   - unique_card_share_slug → flashback_people_unique_card_share_slug_index（#771）
  # 泛化的「任意 unique 冲突」判据会把新增 identity 误归因成 slug_taken（静默
  # 数据丢失），故逐名显式分派，未登记约束名一律原样上抛（fail-closed）。
  @doc false
  def handle_write_error(_changeset, error) do
    cond do
      Cgc2046.Errors.ConstraintConflict.constraint_named?(
        error,
        "flashback_people_unique_public_slug_index"
      ) ->
        Cgc2046.Errors.BusinessError.exception(
          message: "public slug has already been taken",
          code: "flashback_slug_taken",
          fields: [:public_slug]
        )

      Cgc2046.Errors.ConstraintConflict.constraint_named?(
        error,
        "flashback_people_unique_card_share_slug_index"
      ) ->
        # 2^-192 量级的理论碰撞：调用方（CardSharing）据此重铸重试；重试耗尽才出用户面。
        Cgc2046.Errors.BusinessError.exception(
          message: "card share identifier collided, please retry",
          code: "flashback_card_share_conflict",
          fields: [:card_share_slug]
        )

      true ->
        error
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([
      :id,
      :archive_event_id,
      :full_name,
      :surname,
      :city,
      :role,
      :participation,
      :applied_at,
      :public_slug
    ])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
