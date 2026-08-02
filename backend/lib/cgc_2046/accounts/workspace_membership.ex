defmodule Cgc2046.Accounts.WorkspaceMembership do
  @moduledoc """
  工作台成员资格资源（#64）。

  领域模型（multitenancy-调研 §5.2）：WorkspaceMembership 按租户隔离（workspace_id）。
  一个全局用户（User）可属于多个 Workspace；在某个 Workspace 内通过 MembershipRole
  持有多个角色（多角色并集，权限判定取并集）。

  角色分配（#64）：
  - `assign_roles`：替换某成员的整组角色（多角色并集）
  - 仅 Owner/Admin 可分配（`Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin`）
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

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "成员（全局用户）ID"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)

    # 允许跨租户读取（meWorkspaces 需要读取当前用户在所有租户的成员资格），隔离由 policy 保证
    global?(true)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)

    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)

    has_many(:membership_roles, Cgc2046.Accounts.MembershipRole,
      destination_attribute: :membership_id
    )

    many_to_many(:roles, Cgc2046.Accounts.Role,
      through: Cgc2046.Accounts.MembershipRole,
      source_attribute_on_join_resource: :membership_id,
      destination_attribute_on_join_resource: :role_id,
      public?: true
    )
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      argument(:user_id, :uuid)

      change(set_attribute(:user_id, arg(:user_id)))
    end

    update :assign_roles do
      description("分配成员角色（多角色并集，替换整组；仅 Owner/Admin）")
      require_atomic?(false)

      argument(:role_names, {:array, :atom},
        allow_nil?: false,
        constraints: [items: [one_of: [:owner, :admin, :member, :tutor, :volunteer, :learner]]]
      )

      change(Cgc2046.Changes.AssignRoles)
    end
  end

  identities do
    identity(:unique_membership_per_workspace_user, [:workspace_id, :user_id])
  end

  postgres do
    table("workspace_memberships")
    repo(Cgc2046.Repo)

    identity_index_names(unique_membership_per_workspace_user: "wm_unique_ws_user_idx")
  end

  policies do
    # 创建/删除成员：仅 Owner/Admin（角色分配受控）
    policy action_type([:create, :destroy]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 角色分配（update）：仅 Owner/Admin
    policy action_type(:update) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 读取：成员本人可读自己的成员资格；Owner/Admin 可读该工作台全部成员（成员管理）
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:workspace_membership)
    # 成员管理页需要展示成员的角色（多角色并集）
    relationships([:roles])

    queries do
      list(:workspace_members, :read, description: "工作台成员列表（成员本人仅见自己；Owner/Admin 见全部，供成员管理页）")
    end

    mutations do
      update(:assign_roles, :assign_roles, description: "分配成员角色（多角色并集，仅 Owner/Admin）")
    end
  end
end
