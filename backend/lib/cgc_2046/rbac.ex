defmodule Cgc2046.Rbac do
  @moduledoc """
  授权判定核心(严格授权链第 2–4 环,见 docs/spec-平台核心与OpenClacky对接.md §4)。

  职责:
  - `can?/3` — actor 在指定 workspace 是否拥有某权限(读 memberships + 角色预加载,
    多角色权限取**并集**:命中任一角色的 permissions 即放行)
  - `ensure!/3` — 无权时 raise `Ash.Error.Forbidden`(供写 action 首行调用)
  - `member?/2` — actor 是否为该 workspace 成员
  - `seed_default_roles!/2` — 为新 Workspace 初始化默认角色模板
    (Owner/Admin/Tutor/Volunteer/Learner),Owner 自动成为成员并持有 Owner 角色

  默认角色模板与权限集来自 spec §4 权限矩阵(角色是租户内数据库实体,
  非写死枚举;permissions 数组即该角色的权限集,支持扩展)。
  """

  alias Cgc2046.Workspaces.{MembershipRole, Role, WorkspaceMembership}

  import Ash.Query, only: [filter: 2]

  @default_role_names ~w(Owner Admin Tutor Volunteer Learner)

  @default_role_descriptions %{
    "Owner" => "Workspace 所有者:管理成员/角色/邀请/审计与公共资源",
    "Admin" => "Workspace 管理员:管理成员与公共资源,无 Owner 专属权限",
    "Tutor" => "教研老师:创建公共 Agent 与 Workflow,不管理成员",
    "Volunteer" => "志愿者:参与授权 Step,可发邀请(不高于 Admin 级)",
    "Learner" => "学员:仅个人 Agent 与授权 Step"
  }

  # 权限矩阵(spec §4):
  # - 创建个人 Agent / 使用自己个人 Agent = 任何成员 → agent:personal:create(全部角色)
  # - 创建/编辑公共 Agent = Owner/Admin/Tutor(删除仅 Owner/Admin)
  # - 创建/部署 Workflow = Owner/Admin/Tutor
  # - 成员管理(加入/角色分配/移除) = Owner/Admin
  # - 角色管理 = Owner;加入请求审批 = Owner/Admin;邀请 = Owner/Admin/Volunteer
  # - Workspace 级管理(join policy 等)与审计 = Owner
  @default_role_permissions %{
    "Owner" => [
      "agent:personal:create",
      "agent:public:create",
      "agent:public:edit",
      "agent:public:delete",
      "workflow:create",
      "workflow:deploy",
      "member:manage",
      "role:manage",
      "join_request:manage",
      "invitation:create",
      "workspace:manage",
      "audit:view"
    ],
    "Admin" => [
      "agent:personal:create",
      "agent:public:create",
      "agent:public:edit",
      "agent:public:delete",
      "workflow:create",
      "workflow:deploy",
      "member:manage",
      "join_request:manage",
      "invitation:create"
    ],
    "Tutor" => [
      "agent:personal:create",
      "agent:public:create",
      "agent:public:edit",
      "workflow:create",
      "workflow:deploy",
      "invitation:create"
    ],
    "Volunteer" => [
      "agent:personal:create",
      "invitation:create"
    ],
    "Learner" => [
      "agent:personal:create"
    ]
  }

  @doc "默认角色模板:角色名 → 权限集(供测试与审计查看)。"
  def default_role_permissions, do: @default_role_permissions

  @doc "默认角色模板:角色名列表。"
  def default_role_names, do: @default_role_names

  @doc """
  actor 是否拥有指定权限(多角色权限并集)。

  opts 二选一:
  - `:tenant` — workspace_id(uuid)
  - `:workspace` — %Workspace{}

  permission 接受 string 或 atom(`:workflow_create` → `"workflow:create"`)。
  """
  def can?(nil, _permission, _opts), do: false

  def can?(actor, permission, opts) when is_atom(permission) do
    can?(actor, Atom.to_string(permission), opts)
  end

  def can?(actor, permission, opts) do
    with {:ok, workspace_id} <- fetch_workspace_id(opts),
         {:ok, roles} <- member_roles(actor, workspace_id) do
      permission in Enum.flat_map(roles, & &1.permissions)
    else
      _ -> false
    end
  end

  @doc """
  无权时 raise `Ash.Error.Forbidden`,有权返回 `:ok`。

  统一约定:租户资源写 action 首行调用(见 spec §4)。
  """
  def ensure!(actor, permission, opts) do
    if can?(actor, permission, opts) do
      :ok
    else
      raise Ash.Error.Forbidden.exception([])
    end
  end

  @doc "actor 是否为该 workspace 的成员(内部查询绕过 policy,授权判定自身不被干扰)。"
  def member?(nil, _workspace_id), do: false

  def member?(actor, workspace_id) when is_binary(workspace_id) do
    WorkspaceMembership
    |> filter(user_id == ^actor.id)
    |> Ash.read(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  @doc """
  为新 Workspace 初始化默认角色模板,并把 Owner 自动加入为成员(Owner 角色)。

  在 Workspace.create 的 after_action 中调用(workspace 已落库,可 set_tenant)。
  初始化发生在 Owner 成员身份建立之前,故内部用 `authorize?: false` 绕过
  policy 判定——这是 workspace 生命周期内的一次性引导步骤,由已受控的
  Workspace create(仅平台管理员)触发。
  """
  def initialize_workspace!(workspace) do
    seed_default_roles!(workspace)
    grant_owner_membership!(workspace)
    workspace
  end

  @doc "创建默认角色模板(5 个角色,幂等语义:按 name 已存在则跳过)。"
  def seed_default_roles!(workspace) do
    existing =
      Role
      |> Ash.Query.select([:name])
      |> Ash.read!(tenant: workspace.id, authorize?: false)
      |> then(fn roles -> MapSet.new(roles, & &1.name) end)

    for name <- @default_role_names, not MapSet.member?(existing, name) do
      Ash.create!(
        Role,
        %{
          name: name,
          description: @default_role_descriptions[name],
          permissions: @default_role_permissions[name]
        }, tenant: workspace.id, authorize?: false)
    end

    :ok
  end

  @doc "把 workspace.owner_id 用户加入为成员并分配 Owner 角色。"
  def grant_owner_membership!(workspace) do
    membership =
      Ash.create!(WorkspaceMembership, %{user_id: workspace.owner_id},
        tenant: workspace.id,
        authorize?: false
      )

    owner_role =
      Role
      |> filter(name == "Owner")
      |> Ash.read_one!(tenant: workspace.id, authorize?: false)

    Ash.create!(MembershipRole, %{membership_id: membership.id, role_id: owner_role.id},
      tenant: workspace.id,
      authorize?: false
    )

    membership
  end

  defp fetch_workspace_id(opts) do
    cond do
      tenant = opts[:tenant] -> {:ok, tenant}
      workspace = opts[:workspace] -> {:ok, workspace.id}
      true -> :error
    end
  end

  defp member_roles(actor, workspace_id) do
    WorkspaceMembership
    |> filter(user_id == ^actor.id)
    |> Ash.Query.load(:roles)
    |> Ash.read(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, memberships} -> {:ok, Enum.flat_map(memberships, & &1.roles)}
      {:error, _error} -> :error
    end
  end
end
