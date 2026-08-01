defmodule Cgc2046.Changes.AssignRoles do
  @moduledoc """
  替换某成员（WorkspaceMembership）的整组角色（多角色并集）。

  由 `WorkspaceMembership.assign_roles` update action 调用：
  1. change 阶段：只读校验 role_names 对应的角色存在（不写库）
  2. after_action 阶段（policy 授权通过后）：删除旧 MembershipRole 关联并创建新关联

  ## 为什么写库放 after_action

  Ash 的 action 执行顺序为：`changeset()`（执行 change）→ `authorize()`（policy 检查）
  → `commit()`（执行 before_action → data layer → after_action）。
  若在 change 阶段直接写库，会先于 policy 检查修改数据，导致
  `WorkspaceActorIsOwnerOrAdmin` 读到已被修改的角色而误放行（越权漏洞）。
  放 after_action 可保证只有通过授权后才写库。

  内部操作用 `authorize?: false`——外层 update action 已通过
  `WorkspaceActorIsOwnerOrAdmin` 授权，避免重复权限评估。
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Cgc2046.Accounts.{MembershipRole, Role}

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
        Ash.Changeset.after_action(changeset, fn _changeset, result ->
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
