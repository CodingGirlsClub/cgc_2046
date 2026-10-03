defmodule Cgc2046.Accounts.Policies.ActorManagesJoinRequestWorkspace do
  @moduledoc """
  JoinRequest 读取授权的「管理面」FilterCheck：actor 是否为记录所属工作台的
  Owner/Admin（`Role.manage_roles/0` 单源）。

  将管理判定编译为 SQL EXISTS 行级过滤，避免 GraphQL `or` filter
  扩大 Owner/Admin 可见的 JoinRequest 行集。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the join request's workspace"

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
