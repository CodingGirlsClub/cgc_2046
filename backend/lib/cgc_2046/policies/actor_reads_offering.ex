defmodule Cgc2046.Policies.ActorReadsOffering do
  @moduledoc """
  Offering 读取授权：工作台成员可读非 draft；Owner/Admin 可读全部状态。

  过滤器同时约束成员资格与管理角色，确保管理角色只在当前 offering 所属
  工作台内、且属于当前 actor 的 membership 上生效。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor reads offering as a member or workspace manager"

  @impl true
  def filter(nil, _context, _opts), do: expr(is_nil(id))

  def filter(actor, _context, _opts) do
    actor_id = actor.id
    manage_roles = Role.manage_roles()

    expr(
      exists(workspace.memberships, user_id == ^actor_id) and
        (status != :draft or
           exists(
             workspace.memberships,
             user_id == ^actor_id and exists(roles, name in ^manage_roles)
           ))
    )
  end
end
