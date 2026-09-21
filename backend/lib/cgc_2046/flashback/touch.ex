defmodule Cgc2046.Flashback.Touch do
  @moduledoc """
  行为事件（KTD10）：四率看板（R24）的唯一数据源——由 U2 在四个时刻写入：

  - `link_opened`：token 落地（flashbackEnter 成功）；
  - `revealed`：认领显影完成；
  - `sent_to_wall`：寄出（flashbackSendToWall）；
  - `intent_submitted`：回信意图提交（flashbackSubmitToday）。

  追加只写（append-only）：无 update 面，`at` 即建行时刻；度量契约的分子 =
  各事件计数，分母 = 成功送达人数（U8 的 outreach 状态），记忆线/圆梦线分开
  统计（分线维度 = person.participation，聚合在 U11）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @events [:link_opened, :revealed, :sent_to_wall, :intent_submitted]

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    # 落地 token 可溯（首程事件都带；找回进入的场景为 nil）。
    attribute(:token_id, :uuid, public?: true, writable?: true)

    attribute(:event, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @events]
    )

    # 追加只写表：建行时刻即事件时刻，无 updated_at。
    create_timestamp(:at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  postgres do
    table("flashback_touches")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # U2 四时刻写入（authorize?: false 路径）。
    create :create do
      accept([:person_id, :token_id, :event])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :token_id, :event, :at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
