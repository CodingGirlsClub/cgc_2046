defmodule Cgc2046.Accounts.Role do
  @moduledoc """
  租户内角色资源（#64，plan 017 退役 member）。

  领域模型：Role 按租户隔离（workspace_id）。
  成员资格天然 = 存在 `WorkspaceMembership` 行；Role 只保留差异标签
  （workspace 创建时 seed：owner/admin/tutor/volunteer/learner）。
  同一成员可持多个角色（多角色并集，权限判定取并集）。

  角色枚举（差异标签，与设计稿 #67 对齐）：
  - `:owner`：工作台所有者（创建者），可管理成员与角色分配
  - `:admin`：管理员，可管理成员与角色分配
  - `:tutor`：讲师（内容与教学支持，成员级权限）
  - `:volunteer`：志愿者（活动与运营支持，成员级权限）
  - `:learner`：学员（学习与参与，成员级权限；学习 run 的 StepRole / enrolled_learner 判定）

  `:member` 已退役：不再是 Role 枚举项。无差异标签的普通成员 = 空 `MembershipRole`。

  ## 角色枚举单源（G2 收敛，消除 Shotgun Surgery）

  五角色枚举的唯一真源是 `@role_names`，角色中文描述的唯一真源是 `@role_descriptions`，
  分别通过 `role_names/0` 与 `role_descriptions/0` 导出供其它模块编译期引用
  （workspace seed、rbac matrix、workspace_membership assign_roles one_of 等）。
  管理角色子集（可管理成员/角色分配的角色）的唯一真源是 `@manage_roles`，
  通过 `manage_roles/0` 导出供 rbac matrix 与 WorkspaceActorIsOwnerOrAdmin policy 共用。
  退役角色名（仅供存量读取容错与迁移）的唯一真源是 `@retired_role_names`。
  """

  @role_names [:owner, :admin, :tutor, :volunteer, :learner]

  @role_descriptions [
    {:owner, "工作台所有者：拥有全部管理权限"},
    {:admin, "工作台管理员：成员管理、角色分配"},
    {:tutor, "讲师：内容与教学支持"},
    {:volunteer, "志愿者：活动与运营支持"},
    {:learner, "学员：学习与参与"}
  ]

  # 已退役角色名。写入路径（create / assign_roles / 邀请预授权）只用 @role_names；
  # 属性 one_of 含退役名，避免 U2 前读到历史 member 行时 cast 失败。
  @retired_role_names [:member]

  # 管理角色子集（owner/admin，为 @role_names 的子集），
  # 供 Rbac 能力判定与 WorkspaceActorIsOwnerOrAdmin policy 共用（G2 收敛）
  @manage_roles [:owner, :admin]

  @doc "五角色枚举唯一真源（新增角色只改这里）"
  def role_names, do: @role_names

  @doc "已退役角色名（存量读取容错 / 迁移；不可再写入）"
  def retired_role_names, do: @retired_role_names

  @doc "管理角色子集唯一真源（新增可管理角色只改这里）"
  def manage_roles, do: @manage_roles

  @doc "管理角色谓词：管理级 = 可管理成员/角色分配的角色类（唯一真源 `@manage_roles`），与能力矩阵刻意解耦"
  def manage_role?(role), do: role in @manage_roles

  @doc "角色名 → 中文描述唯一真源（workspace seed 复用）"
  def role_descriptions, do: @role_descriptions

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

    attribute(:name, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: @role_names ++ @retired_role_names],
      description: "角色名：owner / admin / tutor / volunteer / learner"
    )

    attribute(:description, :string,
      public?: true,
      writable?: true,
      description: "角色说明"
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

  actions do
    default_accept([:description])
    defaults([:read])

    # 内部 seed 用 create（workspace 创建时自动建立 owner/admin/tutor/volunteer/learner）；
    # 对外策略仍为 never()，仅 authorize?: false 的内部调用可执行
    create :create do
      primary?(true)
      argument(:name, :atom, constraints: [one_of: @role_names])
      change(set_attribute(:name, arg(:name)))
    end
  end

  identities do
    identity(:unique_role_per_workspace, [:workspace_id, :name])
  end

  postgres do
    table("roles")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      # 角色名是租户内公开概念：任何已认证用户可读（用于展示）
      authorize_if(actor_present())
    end

    # 角色为预置数据，外部不允许 create/update/destroy
    policy action_type([:create, :update, :destroy]) do
      authorize_if(never())
    end
  end

  graphql do
    type(:role)
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:tenancy)
    label_field(:name)
  end
end
