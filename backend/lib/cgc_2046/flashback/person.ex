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
  end

  # flashback_people 只有一个 identity（unique_public_slug），按类型判定即可；
  # 日后新增 identity 须改按约束名分派（同 initiative 注记）。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) do
      Cgc2046.Errors.BusinessError.exception(
        message: "public slug has already been taken",
        code: "flashback_slug_taken",
        fields: [:public_slug]
      )
    else
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
