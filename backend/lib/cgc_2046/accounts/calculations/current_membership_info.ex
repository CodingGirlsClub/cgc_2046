defmodule Cgc2046.Accounts.Calculations.CurrentMembershipInfo do
  @moduledoc """
  为 Workspace 计算当前用户（actor）的成员信息（#64 meWorkspaces 契约字段）。

  四个计算字段（my_role_names / my_membership_id / can_access / my_abilities）共用本模块，
  通过 opts[:key] 区分返回值。内部委托 `MembershipContext.memberships_of_actor/1`
  批量加载 actor 在所有租户的成员资格（WorkspaceMembership 已开启 global? true，
  允许跨租户读取），再按 workspace_id 分组，避免 N+1（#2 成员资格读取收敛）。

  my_abilities（#1 能力接口收敛）：与 Rbac.abilities/2 语义**完全一致**（含非成员分支）：
  成员路径由共享纯函数 Rbac.abilities_for/2 从已加载的角色并集派生；非成员分支
  （actor 不在该工作台）平台管理员豁免 view/access/create_workspace、其余为 []。
  返回能力名字符串列表，顺序同 Rbac.abilities_list/0。
  """
  use Ash.Resource.Calculation

  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Rbac

  @impl true
  def calculate(records, opts, %{actor: %{id: _user_id} = actor}) do
    memberships = MembershipContext.memberships_of_actor(actor)

    is_platform_admin = actor_is_platform_admin?(actor)

    by_workspace =
      Enum.group_by(memberships, & &1.workspace_id)
      |> Map.new(fn {workspace_id, [membership | _]} ->
        {workspace_id,
         %{
           my_membership_id: membership.id,
           my_role_names: Enum.map(membership.roles, &Atom.to_string(&1.name)),
           can_access: true,
           my_abilities:
             membership.roles
             |> Enum.map(& &1.name)
             |> Rbac.abilities_for(is_platform_admin)
             |> Enum.map(&Atom.to_string/1)
         }}
      end)

    key = Keyword.get(opts, :key, :my_role_names)

    Enum.map(records, fn workspace ->
      case Map.get(by_workspace, workspace.id) do
        nil ->
          # 非成员分支与 Rbac.abilities/2 语义一致：平台管理员豁免
          # view/access + create_workspace，其余为 []
          if key == :my_abilities do
            non_member_abilities(actor)
          else
            default_for(key)
          end

        info ->
          Map.get(info, key, default_for(key))
      end
    end)
  end

  def calculate(records, opts, _context) do
    key = Keyword.get(opts, :key, :my_role_names)

    Enum.map(records, fn _workspace ->
      default_for(key)
    end)
  end

  defp actor_is_platform_admin?(actor) do
    Map.get(actor, :is_platform_admin, false) == true
  end

  defp non_member_abilities(actor) do
    if actor_is_platform_admin?(actor) do
      Enum.map(Rbac.abilities_for([], true), &Atom.to_string/1)
    else
      []
    end
  end

  defp default_for(:my_role_names), do: []
  defp default_for(:my_membership_id), do: nil
  defp default_for(:can_access), do: false
  defp default_for(:my_abilities), do: []
end
