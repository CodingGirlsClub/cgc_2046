defmodule Cgc2046.Accounts.Policies.ActorManagesInvitationWorkspace do
  @moduledoc """
  Invitation 读取授权的管理面 FilterCheck（#705）：actor 是邀请所属工作台的
  Owner/Admin，角色范围取自 `Role.manage_roles/0`。

  替代 read 的 SimpleCheck 布尔放行，将管理条件编译为逐行 EXISTS，避免客户端
  OR filter 扩大跨工作台返回集合。资源专属路径为 `workspace.memberships`，
  成员角色经 `roles` 判断；沿用 Enrollment / MembershipRole 先例，不泛化路径。
  inviter self-read、PlatformAdmin 全局读面与 validate bypass 仍由资源 policy 保留。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the invitation's workspace"

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
