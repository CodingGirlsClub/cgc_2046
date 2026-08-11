defmodule Cgc2046.Miniprogram.NotificationConsent do
  @moduledoc "小程序订阅消息的一次性授权余额。"

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, allow_nil?: false, writable?: true)

    attribute(:platform, :atom,
      allow_nil?: false,
      writable?: true,
      constraints: [one_of: [:wechat, :tt, :xhs]]
    )

    attribute(:template_key, :string, allow_nil?: false, writable?: true)
    attribute(:remaining_uses, :integer, allow_nil?: false, default: 0, writable?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  identities do
    identity(:unique_user_platform_template, [:user_id, :platform, :template_key])
  end

  actions do
    defaults([:read])
  end

  postgres do
    table("mp_notification_consents")
    repo(Cgc2046.Repo)
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:miniprogram)
  end
end
