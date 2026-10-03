defmodule Cgc2046.Accounts.Policies.ActorManagesInviteBatchWorkspace do
  @moduledoc """
  InviteBatch 读取授权的「管理面」FilterCheck：actor 是否为批次所属工作台的
  Owner/Admin（`Role.manage_roles/0` 单源）。

  将管理判定编译为 SQL EXISTS 行级过滤，避免客户端组合 GraphQL filter 扩大
  InviteBatch 的跨工作台返回行集。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the invite batch's workspace"

  @impl true
  def filter(nil, _context, _opts) do
    expr(false)
  end

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
