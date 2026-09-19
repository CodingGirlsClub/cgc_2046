defmodule Cgc2046.Flashback.Today do
  @moduledoc """
  「今天的你」回信（R8/R13/R17-R20）：每人至多一行（`unique_person`），
  首次提交创建、其后覆写更新；`sent_to_wall_at` 置位 = 已寄出（R11），
  撤回（U2 flashbackRetract）将其清回 nil——名册随之回到结构化卡（R12）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    # 现状 / 想做的事·想学的东西 / 需要什么帮助 / 想对 CGC 说的话（R8）。
    attribute(:now_status, :string, public?: true, writable?: true)
    attribute(:want, :string, public?: true, writable?: true)
    attribute(:need, :string, public?: true, writable?: true)
    attribute(:say, :string, public?: true, writable?: true)

    # Want（想要）/ Give（能给）分类标签（KTD 回信即参与；供需撮合全量阶段启用）。
    attribute(:want_give_tags, {:array, :string}, public?: true, writable?: true, default: [])

    # 今天的你句级雾面（U10 第二刀）：field("now"/"want"/"need"/"say") → spans，
    # 与当年 FogSpans 同坐标（grapheme）同校验；对外渲染按句遮蔽。
    attribute(:fog_spans, :map, public?: true, writable?: true)

    # 动员勾选（R20）：参加 1024 城市活动 / 帮宣传 / 捐赠意向 + 志愿者牵头追问（R8）。
    # 自由 map（键由 U2 输入契约钉住），不出投影面。
    attribute(:mobilization, :map, public?: true, writable?: true, default: %{})

    attribute(:newsletter_opt_in, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true
    )

    # Reconnect 意愿（R19）：求职 / 找项目 / 兴趣社交等。
    attribute(:reconnect_tags, {:array, :string}, public?: true, writable?: true, default: [])

    attribute(:sent_to_wall_at, :utc_datetime_usec, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_person, [:person_id])
  end

  postgres do
    table("flashback_todays")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # U2 flashbackSubmitToday 专用（authorize?: false 路径；upsert 语义由调用方
    # 以 unique_person 冲突重试实现——U3 导入不触本表）。
    create :create do
      accept([
        :person_id,
        :now_status,
        :want,
        :need,
        :say,
        :want_give_tags,
        :mobilization,
        :newsletter_opt_in,
        :reconnect_tags,
        :fog_spans
      ])
    end

    # U10 删除级联专用（authorize?: false 路径——行硬删，PIPL 数据清除）。
    destroy(:destroy)

    update :update do
      require_atomic?(false)

      accept([
        :now_status,
        :want,
        :need,
        :say,
        :want_give_tags,
        :mobilization,
        :newsletter_opt_in,
        :reconnect_tags,
        :fog_spans,
        :sent_to_wall_at
      ])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([
      :id,
      :person_id,
      :newsletter_opt_in,
      :want_give_tags,
      :reconnect_tags,
      :sent_to_wall_at
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
