defmodule Cgc2046.Accounts.Policies.ActorManagesEnrollmentWorkspace do
  @moduledoc """
  Enrollment 读取授权的「管理面」FilterCheck：actor 是否为报名行所属工作台的
  Owner/Admin（`Role.manage_roles/0` 单源）。

  替代 read policy 中的 `WorkspaceActorIsOwnerOrAdmin`（SimpleCheck，#547）：
  SimpleCheck 布尔放行不注入行过滤，`MembershipContext.resolve_workspace_id/1`
  会从客户端 `or` filter 的任一分支提取 workspace_id 并放行整个查询——行集由
  or 组合决定，构成跨租户读面（GraphQL pipeline 无 tenant 注入）。本 check 把
  管理判定编译为 SQL EXISTS 行级过滤，`or` 组合无法扩大返回行集。

  与 `ActorManagesMembershipRoleWorkspace`（MembershipRole 同款修复先例）互补：
  路径硬编码 `workspace.memberships`（Enrollment 专属，enrollment → workspace →
  memberships）；其余同族 SimpleCheck 读面见 #705-#709。
  """

  use Ash.Policy.FilterCheck

  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor manages (owner/admin) the enrollment's workspace"

  @impl true
  def filter(nil, _context, _opts) do
    # 匿名：恒假 filter（0 行）——与 ReadWorkspaceProfileByVisibility 同款纪律
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
