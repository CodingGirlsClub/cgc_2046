defmodule Cgc2046.Rbac do
  @moduledoc """
  统一权限判定模块（#66 A-5-BE Rbac 模块）。

  对外面（C2 收敛后的真实面）：
  - `abilities_list/0` — 能力词汇表（顺序即展示顺序，供契约生成与前端对齐）
  - `abilities_for/2` — 纯判定：角色并集 + 平台管理员标记 → 能力列表，
    与 Workspace.my_abilities 计算字段（CurrentMembershipInfo）共用（#1 语义单源）
  - `matrix/0` — 角色 → 能力矩阵（由 `roles_can?/2` 逐能力派生）
  - `validate_owner_removal!/5` — owner 授予/撤销规则（只有 Owner 能动 owner + 最后 Owner 保护）

  能力清单（切片A 范围）：

  | 能力 | 语义 | 判定 |
  |------|------|------|
  | `:view_workspace` | 查看工作台详情与基本配置 | 成员或平台管理员 |
  | `:access_invite_only` | 访问仅邀请（invite_only）工作台 | 成员或平台管理员 |
  | `:list_members` | 查看工作台全部成员列表 | Owner/Admin（多角色并集） |
  | `:manage_members` | 添加/移除成员 | Owner/Admin |
  | `:assign_roles` | 分配成员角色（多角色并集） | Owner/Admin |
  | `:update_join_policy` | 修改加入策略（#78） | Owner/Admin + 平台管理员豁免 |
  | `:manage_events` | 管理活动/课程/定价/赞助内容（#215） | Owner/Admin |
  | `:create_workspace` | 创建新工作台 | 平台管理员（`is_platform_admin`） |

  规则：
  - 成员资格内角色取**并集**（多角色并集，任一角色支持即支持，与 #64 `WorkspaceActorIsOwnerOrAdmin` 一致）
  - 平台管理员：对 `view_workspace` / `access_invite_only` 有豁免（非成员也可读，与资源 policy 一致）；
    **`update_join_policy` 亦有豁免**（#78：Workspace 全局资源管理能力，平台管理员历史上可更新，能力不回收；
    与 policy 侧并集一致）；管理类能力（`list_members` / `manage_members` / `assign_roles` / `manage_events`）**无豁免**，
    仍按实际 membership 判定——此拒绝是双面契约的能力面，契约真源见
    `Cgc2046.Policies.PlatformAdmin` moduledoc（#66 P2 方向①，#64「平台管理员非成员 canAccess=false」）
  - actor 为 `nil`（匿名）→ 一律 `false`
  - `create_workspace` 是平台级能力，不出现在角色矩阵（与前端 #67 矩阵一致：五角色均为 false）

  与各资源 Ash policies 的关系：资源自身由 `policies do ... end` 强制（如 workspace
  读取、workspace_membership 管理）；policy 面与能力面的分工（双面契约）见
  `Cgc2046.Policies.PlatformAdmin` moduledoc。
  """

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role

  @type ability ::
          :view_workspace
          | :access_invite_only
          | :list_members
          | :manage_members
          | :assign_roles
          | :update_join_policy
          | :manage_events
          | :create_workspace

  @abilities [
    :view_workspace,
    :access_invite_only,
    :list_members,
    :manage_members,
    :assign_roles,
    :update_join_policy,
    :manage_events,
    :create_workspace
  ]

  @manage_abilities [
    :list_members,
    :manage_members,
    :assign_roles,
    :update_join_policy,
    :manage_events
  ]

  @doc "全部能力列表（顺序即展示顺序，与前端 #67 表头一致）"
  def abilities_list, do: @abilities

  @doc """
  纯函数：给定角色名列表与平台管理员标记，返回能力列表（按 `abilities_list/0` 顺序）。

  Workspace.my_abilities 计算字段（CurrentMembershipInfo）共用本函数 ——
  判定语义唯一实现（#1 能力接口收敛）。

  语义（与 `roles_can?/2` + 平台管理员豁免一致）：
  - `create_workspace`：仅平台管理员（不出现在角色矩阵，与 matrix 一致）
  - `view_workspace` / `access_invite_only`：平台管理员或任意 membership（成员基准能力，
    不再经 member 角色判定；角色列表为空时仍具备 view/access）
  - `update_join_policy`：平台管理员豁免或管理角色类（`Role.manage_role?/1`，#78）
  - 管理类能力（list_members / manage_members / assign_roles / manage_events）：管理角色类
  - 其余：false
  """
  @spec abilities_for([atom], boolean) :: [ability]
  def abilities_for(roles, is_platform_admin) do
    Enum.filter(@abilities, fn ability ->
      cond do
        ability == :create_workspace ->
          is_platform_admin

        ability in [:view_workspace, :access_invite_only] ->
          is_platform_admin or roles_can?(roles, ability)

        # #78：update_join_policy 平台管理员豁免（与 policy 并集一致）
        ability == :update_join_policy ->
          is_platform_admin or roles_can?(roles, ability)

        ability in @manage_abilities ->
          roles_can?(roles, ability)

        true ->
          false
      end
    end)
  end

  @doc """
  角色 → 能力矩阵（五角色 × 八能力）。

  与前端权限映射页对齐：
  - owner/admin：view_workspace / access_invite_only / list_members / manage_members / assign_roles / update_join_policy / manage_events 全 true
  - tutor/volunteer/learner：仅 view_workspace / access_invite_only（与无标签成员基准等价）
  - create_workspace：平台管理员专属，五角色均 false

  矩阵由 `roles_can?/2` 逐能力派生（#4 单源收敛，消除静态矩阵双源），
  角色枚举从 Role.role_names/0 单源派生（G2 收敛），顺序与 role.ex @role_names 一致。

  返回 `[%{role: atom, abilities: %{ability => boolean}}]`。
  """
  @spec matrix() :: [%{role: atom, abilities: map}]
  def matrix do
    Enum.map(Role.role_names(), fn role ->
      %{
        role: role,
        abilities: Map.new(@abilities, &{&1, roles_can?([role], &1)})
      }
    end)
  end

  # 纯角色判定（工作台内能力）：成员持有角色名列表 `roles`（多角色并集）是否具备 `ability`。
  #
  # `abilities_for/2` 与 `matrix/0` 均由本函数派生（#4 单源收敛）：
  # - 管理类能力（list_members / manage_members / assign_roles / update_join_policy / manage_events）：
  #   命中 `Role.manage_role?/1`（管理角色单源 Role.manage_roles/0）
  # - view_workspace / access_invite_only：成员即具备
  # - 其余能力（含平台级 create_workspace）：false
  @spec roles_can?([atom], ability) :: boolean
  defp roles_can?(roles, ability) when ability in @manage_abilities do
    Enum.any?(roles, &Role.manage_role?/1)
  end

  defp roles_can?(_roles, ability) when ability in [:view_workspace, :access_invite_only],
    do: true

  defp roles_can?(_roles, _ability), do: false

  @doc """
  校验 owner 移除操作（规则 1 + 最后 Owner 保护），供 assign_roles 和 destroy 共用。

  返回 `:ok` 或 `{:error, changeset_with_error}`。

  ## 参数

  - `changeset` — Ash Changeset，错误将添加到此 changeset
  - `caller` — 操作者 actor（需含 `:id`）
  - `target_user_id` — 目标成员的用户 ID
  - `workspace_id` — 工作台 ID
  - `opts` — 关键字列表：
    - `:removing_owner` — 是否正在移除 owner（destroy 场景传 true；assign_roles 根据 role_names 判断）
    - `:granting_owner` — 是否正在授予 owner（assign_roles 场景传 true）

  ## 规则

  1. 只有 Owner 能授予/撤销 owner（Admin 不能碰）
  2. 撤销 owner 时必须保留至少 1 个 Owner（最后 Owner 保护）
  """
  @spec validate_owner_removal!(Ash.Changeset.t(), term, String.t(), String.t(), keyword) ::
          :ok | {:error, Ash.Changeset.t()}
  def validate_owner_removal!(changeset, caller, target_user_id, workspace_id, opts \\ []) do
    removing_owner = Keyword.get(opts, :removing_owner, true)
    granting_owner = Keyword.get(opts, :granting_owner, false)

    caller_is_owner = :owner in MembershipContext.role_names(caller, workspace_id)
    target_is_owner = :owner in MembershipContext.role_names(%{id: target_user_id}, workspace_id)
    affects_owner = granting_owner or (removing_owner and target_is_owner)

    cond do
      affects_owner and not caller_is_owner ->
        {:error, Ash.Changeset.add_error(changeset, "只有 Owner 能授予或撤销 Owner 角色")}

      removing_owner and target_is_owner and MembershipContext.last_owner?(workspace_id) ->
        {:error, Ash.Changeset.add_error(changeset, "工作台必须至少保留一个 Owner")}

      true ->
        :ok
    end
  end
end
