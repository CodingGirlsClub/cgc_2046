defmodule Cgc2046.Flashback.Endorsement do
  @moduledoc """
  附议（R13）：一人一卡一行（`unique_card_person`）。

  `role_claimed` 为可认领角色（组织者/宣传拉人/场地资源）；`consented_at` 记录
  订阅授权时点（附议提交前 `requestSubscribeMessage`，一次授权一条消息——
  成场通知的配额锚点，U7/U9 消费）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:card_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:role_claimed, :string, public?: true, writable?: true)

    attribute(:consented_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:card, Cgc2046.Flashback.ActionCard,
      source_attribute: :card_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_card_person, [:card_id, :person_id])
  end

  postgres do
    table("flashback_endorsements")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # U5/U7 附议入口（authorize?: false 路径，token/账号双来源）。
    create :create do
      accept([:card_id, :person_id, :role_claimed])
      change(set_attribute(:consented_at, &DateTime.utc_now/0))
    end

    # U5：已附议者改认领角色（幂等——附议计数不重复 +1）。
    update :update_role do
      accept([:role_claimed])
      require_atomic?(false)
    end

    # U10 删除级联专用（authorize?: false 路径）。
    destroy(:destroy)
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :card_id, :person_id, :role_claimed, :consented_at])
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
