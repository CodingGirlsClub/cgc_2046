defmodule Cgc2046.Changes.AssignRoles do
  @moduledoc """
  替换某成员（WorkspaceMembership）的整组角色（多角色并集）。

  由 `WorkspaceMembership.assign_roles` update action 调用：
  1. change 阶段：grant scope 校验（P0 越权修复）+ 只读校验 role_names 对应角色存在（不写库）
  2. after_action 阶段（policy 授权通过后）：删除旧 MembershipRole 关联并创建新关联

  ## 为什么写库放 after_action

  Ash 的 action 执行顺序为：`changeset()`（执行 change）→ `authorize()`（policy 检查）
  → `commit()`（执行 before_action → data layer → after_action）。
  若在 change 阶段直接写库，会先于 policy 检查修改数据，导致
  `WorkspaceActorIsOwnerOrAdmin` 读到已被修改的角色而误放行（越权漏洞）。
  放 after_action 可保证只有通过授权后才写库。

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

  @impl true
  def change(changeset, _opts, context) do
    membership = changeset.data
    workspace_id = membership.workspace_id

    changeset = Ash.Changeset.set_tenant(changeset, workspace_id)

    role_names =
      changeset
      |> Ash.Changeset.get_argument(:role_names)
      |> List.wrap()

    # P0 越权修复：grant scope 校验（change 阶段、写库前；失败用 add_error 不写库）
    case validate_grant_scope(changeset, context.actor, membership, workspace_id, role_names) do
      :ok ->
        case fetch_roles(workspace_id, role_names) do
          {:ok, roles} ->
            Ash.Changeset.after_action(changeset, fn _changeset, result ->
              case replace_roles(workspace_id, membership.id, roles) do
                :ok -> {:ok, result}
                {:error, error} -> {:error, error}
              end
            end)

          {:error, :role_not_found} ->
            Ash.Changeset.add_error(changeset, "角色不存在或不属于该工作台")
        end

      {:error, changeset} ->
        changeset
    end
  end

  # grant scope 校验（P0 安全最小集，判定单源在 Rbac）：
  # - caller_is_owner：调用者在目标工作台持有 owner 角色
  # - target_currently_owner：目标成员当前持有 owner 角色（用 %{id: user_id} map 复用 Rbac.role_names/2）
  # - granting_owner / revoking_owner：本次变更是否授予/撤销 owner
  defp validate_grant_scope(changeset, actor, membership, workspace_id, new_role_names) do
    caller_is_owner = :owner in Rbac.role_names(actor, workspace_id)
    target_currently_owner = :owner in Rbac.role_names(%{id: membership.user_id}, workspace_id)
    granting_owner = :owner in new_role_names
    revoking_owner = target_currently_owner and not granting_owner

    cond do
      # 规则 1：只有 Owner 能授予/撤销 owner（Admin 不能碰）
      (granting_owner or revoking_owner) and not caller_is_owner ->
        {:error, Ash.Changeset.add_error(changeset, "只有 Owner 能授予或撤销 Owner 角色")}

      # 规则 2：撤销 owner 时必须保留至少 1 个 Owner（最后 Owner 保护）
      revoking_owner and Rbac.owner_count(workspace_id) <= 1 ->
        {:error, Ash.Changeset.add_error(changeset, "工作台必须至少保留一个 Owner")}

      true ->
        :ok
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
