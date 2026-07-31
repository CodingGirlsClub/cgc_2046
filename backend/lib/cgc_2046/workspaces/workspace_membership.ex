defmodule Cgc2046.Workspaces.WorkspaceMembership do
  @moduledoc """
  WorkspaceMembership(租户资源):成员与角色的载体。

  T03 落地 attribute 多租户隔离骨架;T04 扩展角色关联与租户授权:
  - `membership_roles` / `roles` 关联(一人多角色)
  - 读需为成员(MemberOfWorkspace);创建/删除需租户权限 `member:manage`
    (Owner/Admin)。角色分配通过 MembershipRole 资源进行,同样受
    `member:manage` 约束。
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

    attribute :user_id, :uuid,
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :user, Cgc2046.Accounts.User,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    has_many :membership_roles, Cgc2046.Workspaces.MembershipRole,
      destination_attribute: :membership_id

    many_to_many :roles, Cgc2046.Workspaces.Role,
      through: Cgc2046.Workspaces.MembershipRole,
      source_attribute_on_join_resource: :membership_id,
      destination_attribute_on_join_resource: :role_id
  end

  identities do
    identity :unique_user_per_workspace, [:workspace_id, :user_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:user_id]
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
    table "workspace_memberships"
    repo Cgc2046.Repo
  end
end
