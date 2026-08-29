defmodule Cgc2046.Miniprogram.ShareScheme do
  @moduledoc """
  微信 URL Scheme 分享链接缓存（plan 011 P1，spike §6 D2-A）。

  同一 (target_kind, target_id, platform) 只保留一份记录：未过期复用、
  过期重生成覆盖（upsert 幂等照 `Cgc2046.Accounts.InvitationCode` 先例）。
  全局资源（scheme 属平台 appid 级产物，不绑 workspace）；到期失效策略
  `min(registration_deadline + 7d, now + 30d)` 在 `ShareSchemeService` 落地
  （D-1；时间源修正见 plan owner 2026-08-18 应答：Event/Course 统一以
  registration_deadline 为 clamp 代理，nil → now+30d）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Miniprogram

  attributes do
    uuid_primary_key(:id)

    attribute(:target_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:event, :course]]
    )

    attribute(:target_id, :uuid, allow_nil?: false)
    attribute(:platform, :atom, allow_nil?: false, constraints: [one_of: [:wechat]])
    attribute(:openlink, :string, allow_nil?: false)
    attribute(:expires_at, :utc_datetime, allow_nil?: false)
    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_target_platform, [:target_kind, :target_id, :platform])
  end

  actions do
    create :create do
      accept([:target_kind, :target_id, :platform, :openlink, :expires_at])
      upsert?(true)
      upsert_identity(:unique_target_platform)
      upsert_fields([:openlink, :expires_at])
    end

    defaults([:read])
  end

  postgres do
    table("miniprogram_share_schemes")
    repo(Cgc2046.Repo)
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  admin do
    resource_group(:miniprogram)
    table_columns([:id, :target_kind, :target_id, :platform, :expires_at, :inserted_at])
  end
end
