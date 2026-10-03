defmodule Cgc2046.Accounts.Policies.ActorManagesWorkspaceMembershipWorkspace do
  @moduledoc """
  WorkspaceMembership 读取授权的「管理面」FilterCheck：actor 是否为记录所属工作台的
  Owner/Admin（`Role.manage_roles/0` 单源）。

  `WorkspaceMembership` 的管理关系路径固定为 `workspace.memberships`：当前成员资格
  → 所属工作台 → 该工作台全部成员资格。把管理判定编译为 SQL EXISTS 行过滤，避免
  GraphQL 客户端的 `or` filter 扩大 Owner/Admin 的返回行集。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the membership's workspace"

  @impl true
  def filter(nil, _context, _opts), do: expr(false)

  def filter(actor, _context, _opts) do
    manage_roles = Role.manage_roles()

    expr(
      exists(
        workspace.memberships,
        user_id == ^actor.id and exists(roles, name in ^manage_roles)
      )
    )
  end
end
