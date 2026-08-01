defmodule Cgc2046.Accounts.MembershipRole do
  @moduledoc """
  成员-角色关联资源（#64）。

  WorkspaceMembership 与 Role 的多对多关联（按租户隔离 workspace_id）。
  一个成员可持多个角色（多角色并集）。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.GlobalApi

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取（meWorkspaces 需要读取当前用户在所有租户的角色），隔离由 policy 保证
    global?(true)
  end

  relationships do
    belongs_to(:membership, Cgc2046.Accounts.WorkspaceMembership,
      allow_nil?: false,
      writable?: true
    )

    belongs_to(:role, Cgc2046.Accounts.Role,
      allow_nil?: false,
      writable?: true
    )
  end

  actions do
    default_accept([:membership_id, :role_id])
    defaults([:read, :create, :destroy])
  end

  identities do
    identity(:unique_membership_role, [:membership_id, :role_id])
  end

  postgres do
    table("membership_roles")
    repo(Cgc2046.Repo)
  end

  policies do
    # 只有 Owner/Admin 能创建/删除角色关联（角色分配受控）
    policy action_type([:create, :destroy]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 读取：仅该 membership 所属用户本人可读（或平台管理员）
    policy action_type(:read) do
      authorize_if(expr(membership.user_id == ^actor(:id)))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:membership_role)
  end
end
