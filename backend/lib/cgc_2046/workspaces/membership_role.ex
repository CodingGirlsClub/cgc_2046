defmodule Cgc2046.Workspaces.MembershipRole do
  @moduledoc """
  MembershipRole(租户内实体,T04):成员-角色关联,一人可持多角色。

  每个记录把某 WorkspaceMembership 与某 Role 绑定;同一成员同一角色
  只允许一条(唯一约束 `unique_membership_role`)。多角色权限取并集,
  判定逻辑见 `Cgc2046.Rbac.can?/3`。

  授权:读需为成员;创建/删除需租户权限 `member:manage`(Owner/Admin)。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      public?: true

    belongs_to :membership, Cgc2046.Workspaces.WorkspaceMembership,
      attribute_type: :uuid,
      public?: true

    belongs_to :role, Cgc2046.Workspaces.Role,
      attribute_type: :uuid,
      public?: true
  end

  identities do
    identity :unique_membership_role, [:membership_id, :role_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:membership_id, :role_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type([:create, :destroy]) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "member:manage"}
      forbid_if always()
    end
  end

  postgres do
    table "membership_roles"
    repo Cgc2046.Repo
  end
end
