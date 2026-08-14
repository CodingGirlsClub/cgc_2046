defmodule Cgc2046.Changes.AssignRoles do
  @moduledoc """
  替换某成员（WorkspaceMembership）的整组角色（多角色并集）。

  由 `WorkspaceMembership.assign_roles` update action 调用：
  1. change 阶段：只读校验 role_names 对应角色存在（不写库）
  2. before_action 阶段（policy 授权通过后、事务内）：取 per-workspace advisory lock →
     grant scope 校验（P0 越权修复 + 最后 Owner 保护）
  3. after_action 阶段（同事务）：删除旧 MembershipRole 关联并创建新关联

  ## 为什么写库放 after_action

  Ash 的 action 执行顺序为：`changeset()`（执行 change）→ `authorize()`（policy 检查）
  → `commit()`（执行 before_action → data layer → after_action）。
  若在 change 阶段直接写库，会先于 policy 检查修改数据，导致
  `WorkspaceActorIsOwnerOrAdmin` 读到已被修改的角色而误放行（越权漏洞）。
  放 after_action 可保证只有通过授权后才写库。

  ## 为什么 grant-scope 读移进 before_action

  grant-scope 校验中的 `owner_count` 读（最后 Owner 保护）与 after_action 的写
  必须在同一事务、同一 `pg_advisory_xact_lock` 下，以闭合 TOCTOU 竞态（孤儿工作台）。
  故将 `validate_grant_scope` 的调用点从 change 阶段移到 before_action 内，
  在取锁后执行。

  ## grant scope 校验（P0 安全最小集）

  原 policy（`WorkspaceActorIsOwnerOrAdmin`）只校验调用者是该 ws 的 Owner/Admin，
  不限制可授予的角色集 → Admin 可给自己/他人加 owner 越权提权；Owner 可自降
  （最后一个）使 workspace 变孤儿。本 change 在写库前追加校验：
  1. 只有 Owner 能授予/撤销 `:owner`（Admin 不能碰 owner）
  2. 撤销 Owner 时必须保留至少 1 个 Owner（最后 Owner 保护）
  3. Admin 管理非 owner 角色不受限（含 Admin↔Admin 互管，YAGNI 先不防）

  内部操作用 `authorize?: false`——外层 update action 已通过
  `WorkspaceActorIsOwnerOrAdmin` 授权，避免重复权限评估。
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Cgc2046.Accounts.{MembershipRole, Role}
  alias Cgc2046.Rbac
  alias Cgc2046.Repo

  @impl true
  def change(changeset, _opts, _context) do
    membership = changeset.data
    workspace_id = membership.workspace_id

    changeset = Ash.Changeset.set_tenant(changeset, workspace_id)

    role_names =
      changeset
      |> Ash.Changeset.get_argument(:role_names)
      |> List.wrap()

    case fetch_roles(workspace_id, role_names) do
      {:ok, roles} ->
        changeset
        |> Ash.Changeset.before_action(fn cs ->
          # 事务内取 per-workspace advisory lock：序列化同工作台的 owner 变更，
          # 使 owner_count 读（validate_grant_scope）与 after_action 写同锁同事务。
          # 注意：Ash 的 require_atomic?(false) 保证 before_action 在 Repo.transaction 内执行，
          # 因此后续 validate_grant_scope 中的 role_names/owner_count 读取与锁在同一连接。
          Repo.acquire_lock!(workspace_id)

          # grant scope 校验委托 Rbac.validate_owner_removal!/5（规则 1 + 最后 Owner 保护，
          # 与 destroy 守卫共用同一实现）。
          new_role_names = Ash.Changeset.get_argument(cs, :role_names) |> List.wrap()
          actor = cs.context[:private][:actor]

          case Rbac.validate_owner_removal!(
                 cs,
                 actor,
                 membership.user_id,
                 workspace_id,
                 removing_owner: :owner not in new_role_names,
                 granting_owner: :owner in new_role_names
               ) do
            :ok -> cs
            {:error, errored} -> errored
          end
        end)
        |> Ash.Changeset.after_action(fn _cs, result ->
          case replace_roles(workspace_id, membership.id, roles) do
            :ok -> {:ok, result}
            {:error, error} -> {:error, error}
          end
        end)

      {:error, :role_not_found} ->
        Ash.Changeset.add_error(changeset, "角色不存在或不属于该工作台")
    end
  end

  defp fetch_roles(workspace_id, role_names) do
    # 空数组 = 清空角色（不报错）
    if role_names == [] do
      {:ok, []}
    else
      query =
        Role
        |> Ash.Query.filter(workspace_id == ^workspace_id and name in ^role_names)

      case Ash.read(query, authorize?: false, tenant: workspace_id) do
        {:ok, roles} when roles != [] -> {:ok, roles}
        _ -> {:error, :role_not_found}
      end
    end
  end

  defp replace_roles(workspace_id, membership_id, roles) do
    with :ok <- clear_old_roles(workspace_id, membership_id) do
      create_new_roles(workspace_id, membership_id, roles)
    end
  end

  defp clear_old_roles(workspace_id, membership_id) do
    query =
      MembershipRole
      |> Ash.Query.filter(membership_id == ^membership_id)

    case Ash.read(query, authorize?: false, tenant: workspace_id) do
      {:ok, existing} ->
        Enum.each(existing, fn mr ->
          Ash.destroy!(mr, authorize?: false)
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_new_roles(workspace_id, membership_id, roles) do
    Enum.each(roles, fn role ->
      Ash.create!(
        MembershipRole,
        %{membership_id: membership_id, role_id: role.id},
        authorize?: false,
        tenant: workspace_id
      )
    end)

    :ok
  end
end
