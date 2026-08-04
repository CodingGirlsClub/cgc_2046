defmodule Cgc2046.Rbac do
  @moduledoc """
  统一权限判定模块（#66 A-5-BE Rbac 模块）。

  提供 `can?/3`、`authorize/3`、`abilities/2` 判定入口（actor + resource + action →
  boolean / 结果），统一封装各资源权限策略，语义与前端 #67 权限矩阵
  （`web/lib/permissions.ts`）对齐。

  能力清单（切片A 范围）：

  | 能力 | 语义 | 判定 |
  |------|------|------|
  | `:view_workspace` | 查看工作台详情与基本配置 | 成员或平台管理员 |
  | `:access_invite_only` | 访问仅邀请（invite_only）工作台 | 成员或平台管理员 |
  | `:list_members` | 查看工作台全部成员列表 | Owner/Admin（多角色并集） |
  | `:manage_members` | 添加/移除成员 | Owner/Admin |
  | `:assign_roles` | 分配成员角色（多角色并集） | Owner/Admin |
  | `:update_join_policy` | 修改加入策略（#78） | Owner/Admin + 平台管理员豁免 |
  | `:create_workspace` | 创建新工作台 | 平台管理员（`is_platform_admin`） |

  规则：
  - 成员资格内角色取**并集**（多角色并集，任一角色支持即支持，与 #64 `WorkspaceActorIsOwnerOrAdmin` 一致）
  - 平台管理员：对 `view_workspace` / `access_invite_only` 有豁免（非成员也可读，与资源 policy 一致）；
    **`update_join_policy` 亦有豁免**（#78：Workspace 全局资源管理能力，平台管理员历史上可更新，能力不回收；
    与 policy 侧并集一致）；管理类能力（`list_members` / `manage_members` / `assign_roles`）**无豁免**，
    仍按实际 membership 判定（#66 P2 决策：方向①判定侧收敛，#64 定稿语义「平台管理员非成员 canAccess=false」）
  - actor 为 `nil`（匿名）→ 一律 `false`
  - `create_workspace` 是平台级能力，不出现在角色矩阵（与前端 #67 矩阵一致：六角色均为 false）

  与各资源 Ash policies 的关系：本模块是**判定入口**（供代码/GraphQL 查询调用），
  资源自身仍由 `policies do ... end` 强制（如 workspace 读取、workspace_membership 管理）。
  两者语义保持一致，测试中互相印证。

  读取委托（2026-08-02 ② 成员资格读取收敛，Q5 决策）：成员资格读取实现在
  `MembershipContext`（成员资格上下文），`role_names/2`、`owner_count/1` 与私有
  `membership/2` 是**有意保留的稳定门面转发** —— 调用方依赖 Rbac 判定词汇契约而非
  读取实现；读取形状可在 seam 侧独立演进（Ash 升级只改 MembershipContext 一处）。
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
          | :create_workspace

  @abilities [
    :view_workspace,
    :access_invite_only,
    :list_members,
    :manage_members,
    :assign_roles,
    :update_join_policy,
    :create_workspace
  ]

  @manage_abilities [:list_members, :manage_members, :assign_roles, :update_join_policy]

  # 管理角色（matrix 与 owner_or_admin? 共用；owner/admin 子集，管理角色单源在 Role.manage_roles/0）
  @manage_roles Role.manage_roles()

  @doc "全部能力列表（顺序即展示顺序，与前端 #67 表头一致）"
  def abilities_list, do: @abilities

  @doc """
  判定 actor 是否具备某能力。

  `opts` 支持：
  - `:workspace_id` — 目标工作台 ID（uuid 字符串）
  - `:workspace` — 已加载的 Workspace 记录（取其 id）
  - `:membership` — 已加载 roles 的 WorkspaceMembership（避免重复查询）

  返回 boolean。
  """
  @spec can?(term, ability, keyword) :: boolean
  def can?(nil, _ability, _opts), do: false

  def can?(actor, :create_workspace, _opts) do
    actor_is_platform_admin?(actor)
  end

  # view/access_invite_only：成员或平台管理员（平台管理员非成员也可读，与资源 policy 一致）
  def can?(actor, ability, opts) when ability in [:view_workspace, :access_invite_only] do
    actor_is_platform_admin?(actor) or workspace_ability?(actor, ability, opts)
  end

  # #78：update_join_policy 平台管理员豁免（Workspace 全局资源管理，非成员也可改，
  # 与 policy 侧并集一致）；专用子句置于通用 manage 子句之前
  def can?(actor, :update_join_policy, opts) do
    actor_is_platform_admin?(actor) or workspace_ability?(actor, :update_join_policy, opts)
  end

  # 管理类能力：仅按 membership 判定（Owner/Admin 多角色并集），平台管理员无豁免
  def can?(actor, ability, opts) when ability in @manage_abilities do
    workspace_ability?(actor, ability, opts)
  end

  def can?(_actor, _ability, _opts), do: false

  @doc """
  authorize 形式：`:ok` 或 `{:error, :forbidden}`。
  """
  @spec authorize(term, ability, keyword) :: :ok | {:error, :forbidden}
  def authorize(actor, ability, opts) do
    if can?(actor, ability, opts), do: :ok, else: {:error, :forbidden}
  end

  @doc """
  当前 actor 在给定上下文（工作台）的可用能力列表（按 `abilities_list/0` 顺序）。

  成员路径与 `can?/3` 共用 `abilities_for/2`（#1 能力接口收敛，语义单源）；
  非成员平台管理员豁免（view/access + create_workspace）与资源 policy 一致。
  """
  @spec abilities(term, keyword) :: [ability]
  def abilities(actor, opts) do
    with {:ok, ws_id} <- workspace_id(opts) do
      case membership(actor, ws_id) do
        nil ->
          # 非成员平台管理员豁免（view/access + create_workspace），
          # 与 abilities_for/2 的平台管理员路径共用同一实现（#1 语义单源）
          if actor_is_platform_admin?(actor), do: abilities_for([], true), else: []

        membership ->
          abilities_for(
            Enum.map(membership.roles, & &1.name),
            actor_is_platform_admin?(actor)
          )
      end
    else
      _ -> []
    end
  end

  @doc """
  纯函数：给定角色名列表与平台管理员标记，返回能力列表（按 `abilities_list/0` 顺序）。

  `can?/3` 成员路径、`abilities/2` 与 Workspace.my_abilities 计算字段
  （CurrentMembershipInfo）共用本函数 —— 判定语义唯一实现（#1 能力接口收敛）。

  语义（与 `roles_can?/2` + 平台管理员豁免一致）：
  - `create_workspace`：仅平台管理员（不出现在角色矩阵，与 matrix 一致）
  - `view_workspace` / `access_invite_only`：平台管理员或成员（成员身份由调用方判定；
    角色列表为空时按成员语义仍具备 view/access）
  - `update_join_policy`：平台管理员豁免或与 `@manage_roles` 有交集（#78）
  - 管理类能力（list_members / manage_members / assign_roles）：与 `@manage_roles` 有交集
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

        # #78：update_join_policy 平台管理员豁免（与 can?/3 专用子句、policy 并集一致）
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
  角色 → 能力矩阵（六角色 × 六能力，G1 扩展）。

  与前端 #67 `MOCK_PERMISSION_MATRIX` 对齐：
  - owner/admin：view_workspace / access_invite_only / list_members / manage_members / assign_roles 全 true
  - member/tutor/volunteer/learner：仅 view_workspace / access_invite_only
  - create_workspace：平台管理员专属，六角色均 false

  矩阵由 `roles_can?/2` 逐能力派生（#4 单源收敛，消除静态矩阵与 `can?/3` 双源），
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

  @doc """
  纯角色判定（工作台内能力）：成员持有角色名列表 `roles`（多角色并集）是否具备 `ability`。

  `can?/3` 的成员路径与 `matrix/0` 均由本函数派生（#4 单源收敛）：
  - 管理类能力（list_members / manage_members / assign_roles / update_join_policy）：
    与 `@manage_roles`（Role.manage_roles/0 单源）有交集
  - view_workspace / access_invite_only：成员即具备
  - 其余能力（含平台级 create_workspace）：false
  """
  @spec roles_can?([atom], ability) :: boolean
  def roles_can?(roles, ability) when ability in @manage_abilities do
    Enum.any?(roles, &(&1 in @manage_roles))
  end

  def roles_can?(_roles, ability) when ability in [:view_workspace, :access_invite_only], do: true

  def roles_can?(_roles, _ability), do: false

  @doc """
  返回 actor 在目标工作台的角色名列表（多角色并集，按 membership.roles 加载顺序）。

  - `actor` 只需含 `:id` 字段（assign_roles grant scope 校验可用 `%{id: user_id}` 传 target）
  - 仅取 actor 的 `:id` 做成员过滤，不做鉴权（内部读取 authorize?: false）
  - 非成员 / 匿名返回 `[]`
  - 读取委托 `MembershipContext.role_names/2`（#2 成员资格读取收敛；同名转发，
    调用方依赖 Rbac 判定门面，读取实现可在 seam 侧独立演进）

  ## Examples

      iex> Rbac.role_names(actor, ws_id)
      [:owner]
  """
  @spec role_names(%{optional(:id) => String.t()} | nil, String.t()) :: [atom]
  def role_names(actor, workspace_id), do: MembershipContext.role_names(actor, workspace_id)

  @doc """
  返回目标工作台当前持有 owner 角色的成员数（按 membership 去重，一人多角色只算 1 次）。

  用于 assign_roles 的「最后 Owner 保护」（撤销 owner 时须保留至少 1 个 Owner）。
  频次极低，直接加载 memberships + roles 统计；tenant 隔离由 multitenancy（workspace_id）保证。
  读取委托 `MembershipContext.owner_count/1`（#2 成员资格读取收敛）。
  """
  @spec owner_count(String.t()) :: non_neg_integer
  def owner_count(workspace_id), do: MembershipContext.owner_count(workspace_id)

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

    caller_is_owner = :owner in role_names(caller, workspace_id)
    target_is_owner = :owner in role_names(%{id: target_user_id}, workspace_id)
    affects_owner = granting_owner or (removing_owner and target_is_owner)

    cond do
      affects_owner and not caller_is_owner ->
        {:error, Ash.Changeset.add_error(changeset, "只有 Owner 能授予或撤销 Owner 角色")}

      removing_owner and target_is_owner and owner_count(workspace_id) <= 1 ->
        {:error, Ash.Changeset.add_error(changeset, "工作台必须至少保留一个 Owner")}

      true ->
        :ok
    end
  end

  # -- 能力判定 ---------------------------------------------------------------

  defp workspace_ability?(actor, ability, opts) do
    with {:ok, ws_id} <- workspace_id(opts) do
      case membership(actor, ws_id) do
        nil ->
          false

        membership ->
          ability in abilities_for(Enum.map(membership.roles, & &1.name), false)
      end
    else
      _ -> false
    end
  end

  # -- 辅助 -----------------------------------------------------------------

  defp actor_is_platform_admin?(actor) do
    actor.is_platform_admin == true
  end

  defp workspace_id(opts) do
    cond do
      Keyword.has_key?(opts, :workspace_id) ->
        {:ok, Keyword.fetch!(opts, :workspace_id)}

      Keyword.has_key?(opts, :workspace) ->
        {:ok, Keyword.fetch!(opts, :workspace).id}

      Keyword.has_key?(opts, :membership) ->
        {:ok, Keyword.fetch!(opts, :membership).workspace_id}

      true ->
        :error
    end
  end

  # 读取 actor 在目标工作台的成员资格（含 roles，多角色并集）。
  # 复用与 #64 WorkspaceActorIsOwnerOrAdmin 一致的读取方式（tenant 隔离 + global 跨租户），
  # 实现委托 MembershipContext.membership_of/2（#2 成员资格读取收敛）。
  defp membership(actor, workspace_id), do: MembershipContext.membership_of(actor, workspace_id)
end
