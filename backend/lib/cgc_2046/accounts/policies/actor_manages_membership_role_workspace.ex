defmodule Cgc2046.Accounts.Policies.ActorManagesMembershipRoleWorkspace do
  @moduledoc """
  MembershipRole 读取授权的「管理面」FilterCheck：actor 是否为记录所属工作台的
  Owner/Admin（`Role.manage_roles/0` 单源）。

  与 `WorkspaceActorIsOwnerOrAdmin`（SimpleCheck，运行时判定）互补：本 check 编译
  为 SQL EXISTS，可下推进 lateral join / relationship load。MembershipRole 的
  read policy 若只挂 SimpleCheck，owner/admin 视角的 `load(:roles)` 在 filter-check
  混合 policy 下退化为纯 filter 分支——他人行被 `membership.user_id == actor.id`
  滤空（list_members 成员管理面只见自己的角色，#写读不一致误报的根因）。

  路径硬编码 `membership.workspace.memberships`（MembershipRole 专属）：当前唯一
  调用方，不做 path 泛化（YAGNI）；`ActorIsWorkspaceMemberVia` 已覆盖泛化成员判定。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the membership role's workspace"

  @impl true
  def filter(nil, _context, _opts) do
    # 匿名：恒假 filter（0 行）——与 ReadWorkspaceProfileByVisibility 同款纪律
    expr(exists(membership, user_id == nil))
  end

  def filter(actor, _context, _opts) do
    manage_roles = Role.manage_roles()

    expr(
      exists(
        membership.workspace.memberships,
        user_id == ^actor.id and exists(roles, name in ^manage_roles)
      )
    )
  end
end
