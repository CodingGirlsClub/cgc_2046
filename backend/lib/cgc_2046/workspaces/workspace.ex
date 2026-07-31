defmodule Cgc2046.Workspaces.Workspace do
  @moduledoc """
  Workspace(全局资源,租户的根;自身不按租户隔离)。

  字段:slug(全局唯一,展示用)、name、join_policy(open/request/invite_only)、
  owner(创建时由平台管理员指定的 Owner)。

  授权(见 docs/spec-平台核心与OpenClacky对接.md §4):
  - 仅平台管理员(`User.is_platform_admin`)可创建并指定 Owner
  - 已认证用户可读(公开发现页在 T13 细化)
  - 加入策略修改等后续操作随各票落地(当前仅 create/read)
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key :id

    attribute :slug, :string,
      allow_nil?: false,
      public?: true

    attribute :name, :string,
      allow_nil?: false,
      public?: true

    attribute :join_policy, :atom,
      allow_nil?: false,
      default: :request,
      constraints: [one_of: [:open, :request, :invite_only]],
      public?: true

    attribute :owner_id, :uuid,
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :owner, Cgc2046.Accounts.User, attribute_type: :uuid
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:slug, :name, :join_policy, :owner_id]

      change after_action(fn _changeset, workspace, _context ->
               Cgc2046.Rbac.initialize_workspace!(workspace)
               {:ok, workspace}
             end)
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:is_platform_admin, true)
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  postgres do
    table "workspaces"
    repo Cgc2046.Repo
  end
end
