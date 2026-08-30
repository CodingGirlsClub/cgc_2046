defmodule Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin do
  @moduledoc """
  判断 actor 是否为目标工作台（租户）的 Owner 或 Admin。

  用于角色分配 / 成员管理等管理操作的授权（#64）：
  - 匿名（actor 为 nil）→ 拒绝
  - 普通成员 / 非成员 → 拒绝
  - 多角色并集：成员持 owner 或 admin 任一角色即通过

  ## 场景说明

  1. update（assign_roles）：从 changeset.tenant 或 changeset.data.workspace_id 取工作台
  2. list query（成员列表）：tenant 可能为空（global 查询），从 filter 提取 workspace_id
  3. get-by-id（GraphQL update mutation 先读目标记录）：filter 只有 id，
     按 id 读出记录后再取 workspace_id

  本模块是**薄适配器**：工作台 id 解析（含 Ash filter struct 提取）与成员资格读取
  全部委托 `MembershipContext`（#2 成员资格读取收敛）；管理判定委托
  `Role.manage_role?/1`（单源 `Role.manage_roles/0`）。Ash 3.31 filter
  struct 匹配细节见 MembershipContext 的 `resolve_workspace_id/1` 与钉测。
  """
  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Role

  @impl true
  def describe(_opts), do: "actor is owner or admin of the target workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    case MembershipContext.resolve_workspace_id(context) do
      nil ->
        false

      workspace_id ->
        manages_workspace?(actor, workspace_id)
    end
  end

  # 管理判定：成员角色多角色并集，任一命中 Role.manage_role?/1（owner/admin，
  # 单源 Role.manage_roles/0）即通过
  defp manages_workspace?(actor, workspace_id) do
    actor
    |> MembershipContext.role_names(workspace_id)
    |> Enum.any?(&Role.manage_role?/1)
  end
end
