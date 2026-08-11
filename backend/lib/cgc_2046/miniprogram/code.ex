defmodule Cgc2046.Miniprogram.Code do
  @moduledoc "平台小程序码缓存；同一 Invitation/平台只保留一份有效码。"

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)
    attribute(:workspace_id, :uuid, allow_nil?: false, writable?: false)
    attribute(:invitation_id, :uuid, allow_nil?: false, writable?: true)

    attribute(:platform, :atom,
      allow_nil?: false,
      writable?: true,
      constraints: [one_of: [:wechat, :tt, :xhs]]
    )

    attribute(:scene, :string,
      allow_nil?: false,
      writable?: true,
      constraints: [match: ~r/^[A-Za-z0-9_]{1,32}$/]
    )

    attribute(:code, :binary, allow_nil?: false, writable?: true)
    attribute(:expires_at, :utc_datetime, allow_nil?: false, writable?: true)
    create_timestamp(:inserted_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:invitation, Cgc2046.Accounts.Invitation, define_attribute?: false)
  end

  identities do
    identity(:unique_invitation_platform, [:invitation_id, :platform], all_tenants?: true)
    identity(:unique_scene, [:scene], all_tenants?: true)
  end

  actions do
    create :create do
      accept([:invitation_id, :platform, :scene, :code, :expires_at])
      upsert?(true)
      upsert_identity(:unique_invitation_platform)
      upsert_fields([:scene, :code, :expires_at])

      change(fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :workspace_id, changeset.tenant)
      end)
    end

    defaults([:read])
  end

  postgres do
    table("miniprogram_codes")
    repo(Cgc2046.Repo)
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:miniprogram)
    table_columns([:id, :workspace_id, :platform, :scene, :expires_at, :inserted_at])
  end
end
