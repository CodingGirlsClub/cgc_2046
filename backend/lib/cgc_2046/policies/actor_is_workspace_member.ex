defmodule Cgc2046.Policies.ActorIsWorkspaceMember do
  @moduledoc """
  判断 actor 是否为目标工作台（租户）的成员（ADR-0004 per-workspace profile 写授权）。

  用于 WorkspaceProfile 的 update / set_ui_theme 授权：写本人档案还须是该
  workspace 的成员（`MembershipContext.membership_of/2` 非 nil），保证 per-workspace
  语义——用户只能编辑自己**已加入**工作台的档案。

  工作台 id 解析委托 `MembershipContext.resolve_workspace_id/1`（与
  WorkspaceActorIsOwnerOrAdmin 同一解析路径，含 Ash filter struct 提取）。
  """
  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.MembershipContext

  @impl true
  def describe(_opts), do: "actor is a member of the target workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    case MembershipContext.resolve_workspace_id(context) do
      nil ->
        false

      workspace_id ->
        MembershipContext.membership_of(actor, workspace_id) != nil
    end
  end
end
