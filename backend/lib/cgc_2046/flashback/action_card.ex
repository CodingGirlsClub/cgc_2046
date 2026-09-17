defmodule Cgc2046.Flashback.ActionCard do
  @moduledoc """
  Action 卡（R13/F6）：意愿池语义的四态生命周期
  `proposed → forming → scheduled → done`。

  - 建卡仅管理员（从 Want/Give 导出人工挑卡，pilot 无自动聚类）；
  - `scheduled` 由管理员确认成场时回填 `event_id`（真实 Event 挂 1024
    Initiative，编排属 U7；本表只持引用，不设跨域 relationship——Event 是
    租户资源，全局卡直读会踩 tenant 边界）；
  - done 回贴（U7/R13）：活动照片 data-URL（头像先例同款校验）+ 回顾文字，
    由 `ActionCards.mark_done/3` 显式置位（照片校验在域层）；
  - 无未成场终止机制（附议即表态，成不成场由运营裁量）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @statuses [:proposed, :forming, :scheduled, :done]

  attributes do
    uuid_primary_key(:id)

    attribute(:title, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:city, :string, public?: true, writable?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :proposed,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses]
    )

    # 提议人（回信意愿的来源校友；管理员挑卡时录入）。
    attribute(:proposer_person_id, :uuid, public?: true, writable?: true)

    # 成场回填（scheduled 起）；done 态回贴照片/回顾（U7）。
    attribute(:event_id, :uuid, public?: true, writable?: false)

    # done 回贴（R13「落地有照片回流」）：活动照片 data-URL（MIME 白名单 +
    # ~3MB 上限，头像先例 workspace_profile.ex 同款口径）；回顾文字。
    attribute(:photo_url, :string, public?: true, writable?: false)
    attribute(:recap, :string, public?: true, writable?: false)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:proposer, Cgc2046.Flashback.Person,
      source_attribute: :proposer_person_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    has_many(:endorsements, Cgc2046.Flashback.Endorsement, destination_attribute: :card_id)
  end

  postgres do
    table("flashback_action_cards")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # 管理员建卡（U7 入口；policy gate PlatformAdmin——U1 变异验证钉住点）。
    create :create do
      accept([:title, :city, :proposer_person_id])
    end

    # 服务端内部更新面（U7 状态机与成场回填用；title/city 可改）。
    update :update do
      require_atomic?(false)
      accept([:title, :city])
    end

    # 成场回填（U7 编排专用：event_id + status 只由 ActionCards.schedule 落点，
    # force_change 路径，不对任何入口开放）。
    update :schedule do
      require_atomic?(false)
      accept([])
    end

    # done 回贴（U7：photo_url/recap + status；照片校验在域层 ActionCards）。
    update :mark_done do
      require_atomic?(false)
      accept([])
    end

    # 状态转移（服务端内部：Endorsements 首条附议 proposed→forming）。
    update :advance_status do
      require_atomic?(false)
      accept([])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([
      :id,
      :title,
      :city,
      :status,
      :proposer_person_id,
      :event_id,
      :photo_url,
      :recap
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
