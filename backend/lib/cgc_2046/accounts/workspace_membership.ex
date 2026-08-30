defmodule Cgc2046.Accounts.WorkspaceMembership do
  @moduledoc """
  工作台成员资格资源（#64）。

  领域模型（multitenancy-调研 §5.2）：WorkspaceMembership 按租户隔离（workspace_id）。
  一个全局用户（User）可属于多个 Workspace；在某个 Workspace 内通过 MembershipRole
  持有多个角色（多角色并集，权限判定取并集）。

  角色分配（#64）：
  - `assign_roles`：替换某成员的整组角色（多角色并集）
  - 仅 Owner/Admin 可分配（`Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin`）
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

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

  calculations do
    # P1-4 G6：暴露成员 user 的 email/displayName。嵌套 `user` 关系加载会被
    # User read policy 滤空（默认 only_me 仅本人可读），故平铺 LEFT JOIN 绕过。
    # 安全契约与 quirk 知识见 BypassReads（旁路读取面）moduledoc。
    calculate(:user_email, :string, expr(user.email),
      public?: true,
      description: "成员邮箱（平铺自 user 关系，P1 G6）"
    )

    calculate(:user_display_name, :string, expr(user.display_name),
      public?: true,
      description: "成员昵称（平铺自 user 关系，P1 G6）"
    )

    # P1-4 G7：加入时间 = inserted_at（AshGraphql 未暴露 createdAt，补平铺字段）
    calculate(:joined_at, :utc_datetime, expr(inserted_at),
      public?: true,
      description: "加入时间（P1 G7，= inserted_at）"
    )
  end

  actions do
    default_accept([])
    defaults([:read])

    # destroy 显式化：补 last-owner 守卫（与 assign_roles 同一不变量）
    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      # 内联 change 函数为 2 参数 (changeset, context)——Ash 3.31 的
      # Ash.Resource.Change.Function 以 fun.(changeset, context) 调用（function.ex:9），
      # 3 参数写法编译能过但运行时 BadArityError。
      change(fn changeset, _context ->
        membership = changeset.data
        workspace_id = membership.workspace_id
        cs = Ash.Changeset.set_tenant(changeset, workspace_id)

        Ash.Changeset.before_action(cs, fn c ->
          # 在 Repo.transaction 内执行锁获取和角色读取，确保同一连接：
          # pg_advisory_xact_lock 是事务级锁，若 role_names 的 Ash.read 走不同连接
          # 则锁不保护读。显式事务保证连接一致。
          Cgc2046.Repo.acquire_lock!(workspace_id)

          # actor 从 before_action 回调参数 c 取（commit 阶段，actor 已注入）；
          # 外层 cs 是 change 注册时的快照，此时 actor 可能尚未注入。
          actor = c.context[:private][:actor]

          # owner 移除校验委托 Rbac.validate_owner_removal!/5（规则 1 + 最后 Owner 保护，
          # 与 assign_roles 共用同一实现）。destroy 场景：removing_owner=true, granting_owner=false。
          case Cgc2046.Accounts.Rbac.validate_owner_removal!(
                 c,
                 actor,
                 membership.user_id,
                 workspace_id,
                 removing_owner: true,
                 granting_owner: false
               ) do
            :ok -> c
            {:error, errored} -> errored
          end
        end)
      end)
    end

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
        constraints: [items: [one_of: Cgc2046.Accounts.Role.role_names()]]
      )

      change(Cgc2046.Accounts.Changes.AssignRoles)
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
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 角色分配（update）：仅 Owner/Admin
    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 读取：成员本人可读自己的成员资格；Owner/Admin 可读该工作台全部成员（成员管理）
    # platform_admin bypass（Phase 10 P2）：非成员 platform_admin 可读全部成员
    # （R13 admin 详情页成员列表），对齐 Phase 2 的 User/ToolCallLog/PendingOperation 模式。
    # 双面契约见 `Cgc2046.Accounts.Policies.PlatformAdmin` moduledoc。
    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
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

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:tenancy)
  end
end
