defmodule Cgc2046.Sponsorship.Policies.ActorManagesSponsorshipWorkspace do
  @moduledoc """
  Sponsorship 管理读面按行所属工作台授权（#709）。

  SimpleCheck 从客户端 OR filter 提取工作台后会布尔放行整个查询。
  此资源专属 check 经 workspace.memberships → roles 编译 SQL EXISTS，
  仅允许 actor 管理的工作台行；本人读取与 PlatformAdmin 仍由原分支授权。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the sponsorship's workspace"

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
