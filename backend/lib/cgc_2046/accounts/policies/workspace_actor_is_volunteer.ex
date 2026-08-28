defmodule Cgc2046.Accounts.Policies.WorkspaceActorIsVolunteer do
  @moduledoc """
  判断 actor 是否为目标工作台（租户）的 Volunteer。

  用于邀请创建等操作的授权（#31）：
  - 匿名（actor 为 nil）→ 拒绝
  - 非成员 / 其他角色 → 拒绝
  - 成员持 volunteer 角色即通过

  委托 MembershipContext 解析工作台 id 与角色名读取。
  """
  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.MembershipContext

  @impl true
  def describe(_opts), do: "actor is volunteer of the target workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    case MembershipContext.resolve_workspace_id(context) do
      nil ->
        false

      workspace_id ->
        actor
        |> MembershipContext.role_names(workspace_id)
        |> Enum.member?(:volunteer)
    end
  end
end
