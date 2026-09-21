defmodule Cgc2046.Flashback.Quote do
  @moduledoc """
  单句金句（R37）：每个授权圈选段一行，稳定 UUID——编辑圈选原地改 span
  （id 不变，旧分享链接与点赞保留）；单句撤回 = `hidden_at` 可逆；整份授权
  撤回（license.hidden_at）由 `Cgc2046.Flashback.Quotes.sync_license_hidden/1`
  级联置位/恢复。

  ## 宿主（双宿主）

  - `question_key` 指向当年答案 → `answer_id` 引用该行（文本渲染时按 span
    切片，不复制文本）；
  - `question_key` 为 `today.now/want/need/say` → 宿主是 `flashback_todays`
    字段，`answer_id` 为 nil（渲染按 question_key 回落）。

  ## 生命周期同步

  Quote 行由 `Cgc2046.Flashback.Quotes.sync_for_license/1` 单一入口维护：
  授权变更（set_quote_license 两入口）、雾改剪句（prune_license_after_fog）、
  下线/恢复（set_hidden）都经它收敛——被剪掉的 span 对应行即删（其点赞随
  FK 级联删除），新增 span 补行，共有 span 原地更新（id 稳定）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:quote_license_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    # today.* 宿主无 answer 行 → 可空
    attribute(:answer_id, :uuid, public?: true, writable?: true)

    attribute(:question_key, :string, allow_nil?: false, public?: true, writable?: true)

    # 圈选区间（grapheme 偏移）：%{"start" => int, "len" => int}
    attribute(:span, :map,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [
        fields: [
          start: [type: :integer, allow_nil?: false],
          len: [type: :integer, allow_nil?: false]
        ]
      ]
    )

    # 城市/年份快照（生成时取 person/archive 现值；sync 时以现值刷新——
    # 「快照」指不随渲染时档案改动而变，授权变更时跟随 person 最新值）
    attribute(:city, :string, public?: true, writable?: true)
    attribute(:year, :integer, public?: true, writable?: true)

    # 单句撤回（可逆）；license 级联由服务层同步
    attribute(:hidden_at, :utc_datetime_usec, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:quote_license, Cgc2046.Flashback.QuoteLicense,
      source_attribute: :quote_license_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:answer, Cgc2046.Flashback.Answer,
      source_attribute: :answer_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    has_many(:likes, Cgc2046.Flashback.Like)
  end

  postgres do
    table("flashback_quotes")
    repo(Cgc2046.Repo)

    references do
      reference(:quote_license, on_delete: :delete)
      reference(:answer, on_delete: :delete)
    end
  end

  actions do
    defaults([:read])

    # Quotes.sync_for_license/1 专用（authorize?: false 路径）。
    create :create do
      accept([:quote_license_id, :answer_id, :question_key, :span, :city, :year, :hidden_at])
    end

    update :update do
      require_atomic?(false)
      accept([:answer_id, :question_key, :span, :city, :year, :hidden_at])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :quote_license_id, :question_key, :city, :year, :hidden_at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
