defmodule Cgc2046.Accounts.Policies.WorkspaceActorIsOwner do
  @moduledoc """
  判断 actor 是否为目标工作台（租户）的 **Owner**（#676 draft 删除收窄面）。

  用于不可逆的 draft 删除授权（`Course :delete` / `Event :delete`）：
  - 匿名（actor 为 nil）→ 拒绝
  - 普通成员 / 非成员 → 拒绝
  - **admin 角色 → 拒绝**（与 `WorkspaceActorIsOwnerOrAdmin` 的 owner/admin 并集
    刻意不同：删除不可逆，收窄到单 owner 角色；平台管理员豁免由资源 policy 的
    `authorize_if(PlatformAdmin)` 并列声明，不在本 check 内）

  本模块是**薄适配器**：工作台 id 解析（含 Ash filter struct 提取）与成员资格读取
  全部委托 `MembershipContext`（#2 成员资格读取收敛）；owner 判定委托
  `Rbac.owner?/2`（判定单源在 Rbac，见其 `:owner in role_names` 先例）。Ash 3.31
  filter struct 匹配细节见 `MembershipContext.resolve_workspace_id/1` 与钉测。
  """
  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Rbac

  @impl true
  def describe(_opts), do: "actor is owner of the target workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    case MembershipContext.resolve_workspace_id(context) do
      nil -> false
      workspace_id -> Rbac.owner?(actor, workspace_id)
    end
  end
end
