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
  | `:create_workspace` | 创建新工作台 | 平台管理员（`is_platform_admin`） |

  规则：
  - 成员资格内角色取**并集**（多角色并集，任一角色支持即支持，与 #64 `WorkspaceActorIsOwnerOrAdmin` 一致）
  - 平台管理员：对 `view_workspace` / `access_invite_only` 有豁免（非成员也可读，与资源 policy 一致）；
    管理类能力（`list_members` / `manage_members` / `assign_roles`）**无豁免**，仍按实际 membership 判定
    （#66 P2 决策：方向①判定侧收敛，#64 定稿语义「平台管理员非成员 canAccess=false」）
  - actor 为 `nil`（匿名）→ 一律 `false`
  - `create_workspace` 是平台级能力，不出现在角色矩阵（与前端 #67 矩阵一致：六角色均为 false）

  与各资源 Ash policies 的关系：本模块是**判定入口**（供代码/GraphQL 查询调用），
  资源自身仍由 `policies do ... end` 强制（如 workspace 读取、workspace_membership 管理）。
  两者语义保持一致，测试中互相印证。
  """

  require Ash.Query

  alias Cgc2046.Accounts.Role
  alias Cgc2046.Accounts.WorkspaceMembership

  @type ability ::
          :view_workspace
          | :access_invite_only
          | :list_members
          | :manage_members
          | :assign_roles
          | :create_workspace

  @abilities [
    :view_workspace,
    :access_invite_only,
    :list_members,
    :manage_members,
    :assign_roles,
    :create_workspace
  ]

  @manage_abilities [:list_members, :manage_members, :assign_roles]

  # 管理角色（matrix 与 owner_or_admin? 共用；owner/admin 子集，枚举单源在 Role.role_names/0）
  @manage_roles [:owner, :admin]

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
  """
  @spec abilities(term, keyword) :: [ability]
  def abilities(actor, opts) do
    Enum.filter(@abilities, &can?(actor, &1, opts))
  end

  @doc """
  静态角色 → 能力矩阵（六角色 × 六能力，G1 扩展）。

  与前端 #67 `MOCK_PERMISSION_MATRIX` 对齐：
  - owner/admin：view_workspace / access_invite_only / list_members / manage_members / assign_roles 全 true
  - member/tutor/volunteer/learner：仅 view_workspace / access_invite_only
  - create_workspace：平台管理员专属，六角色均 false

  返回 `[%{role: atom, abilities: %{ability => boolean}}]`。
  """
  @spec matrix() :: [%{role: atom, abilities: map}]
  def matrix do
    manager_abilities = %{
      view_workspace: true,
      access_invite_only: true,
      list_members: true,
      manage_members: true,
      assign_roles: true,
      create_workspace: false
    }

    member_abilities = %{
      view_workspace: true,
      access_invite_only: true,
      list_members: false,
      manage_members: false,
      assign_roles: false,
      create_workspace: false
    }

    # 角色枚举从 Role.role_names/0 单源派生（G2 收敛），顺序与 role.ex @role_names 一致
    Enum.map(Role.role_names(), fn role ->
      %{
        role: role,
        abilities: if(role in @manage_roles, do: manager_abilities, else: member_abilities)
      }
    end)
  end

  @doc """
  返回 actor 在目标工作台的角色名列表（多角色并集，按 membership.roles 加载顺序）。

  - `actor` 只需含 `:id` 字段（assign_roles grant scope 校验可用 `%{id: user_id}` 传 target）
  - 非成员 / 匿名返回 `[]`
  - 供 assign_roles 越权修复（P0）与其它判定复用

  ## Examples

      iex> Rbac.role_names(actor, ws_id)
      [:owner]
  """
  @spec role_names(term, String.t()) :: [atom]
  def role_names(nil, _workspace_id), do: []

  def role_names(actor, workspace_id) do
    case membership(actor, workspace_id) do
      nil -> []
      membership -> Enum.map(membership.roles, & &1.name)
    end
  end

  @doc """
  返回目标工作台当前持有 owner 角色的成员数（按 membership 去重，一人多角色只算 1 次）。

  用于 assign_roles 的「最后 Owner 保护」（撤销 owner 时须保留至少 1 个 Owner）。
  频次极低，直接加载 memberships + roles 统计；tenant 隔离由 multitenancy（workspace_id）保证。
  """
  @spec owner_count(String.t()) :: non_neg_integer
  def owner_count(workspace_id) do
    query =
      WorkspaceMembership
      |> Ash.Query.load(:roles)

    case Ash.read(query, authorize?: false, tenant: workspace_id) do
      {:ok, memberships} ->
        Enum.count(memberships, fn membership ->
          Enum.any?(membership.roles, &(&1.name == :owner))
        end)

      _ ->
        0
    end
  end

  # -- 能力判定 ---------------------------------------------------------------

  defp workspace_ability?(actor, ability, opts) do
    with {:ok, ws_id} <- workspace_id(opts) do
      case membership(actor, ws_id) do
        nil ->
          false

        membership ->
          cond do
            ability in @manage_abilities -> owner_or_admin?(membership)
            ability in [:view_workspace, :access_invite_only] -> true
            true -> false
          end
      end
    else
      _ -> false
    end
  end

  defp owner_or_admin?(membership) do
    Enum.any?(membership.roles, fn role -> role.name in @manage_roles end)
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
  # 复用与 #64 WorkspaceActorIsOwnerOrAdmin 一致的读取方式（tenant 隔离 + global 跨租户）。
  defp membership(actor, workspace_id) do
    query =
      WorkspaceMembership
      |> Ash.Query.filter(user_id == ^actor.id)
      |> Ash.Query.load(:roles)

    case Ash.read(query, actor: actor, authorize?: false, tenant: workspace_id) do
      {:ok, [membership | _]} -> membership
      _ -> nil
    end
  end
end
