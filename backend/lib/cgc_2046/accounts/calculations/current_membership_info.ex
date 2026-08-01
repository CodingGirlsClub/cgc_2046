defmodule Cgc2046.Accounts.Calculations.CurrentMembershipInfo do
  @moduledoc """
  为 Workspace 计算当前用户（actor）的成员信息（#64 meWorkspaces 契约字段）。

  三个计算字段（my_role_names / my_membership_id / can_access）共用本模块，
  通过 opts[:key] 区分返回值。内部批量加载 actor 在所有租户的成员资格
  （WorkspaceMembership 已开启 global? true，允许跨租户读取），再按 workspace_id
  分组，避免 N+1。
  """
  use Ash.Resource.Calculation

  require Ash.Query

  alias Cgc2046.Accounts.WorkspaceMembership

  @impl true
  def calculate(records, opts, %{actor: %{id: user_id}}) do
    query =
      WorkspaceMembership
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.load(:roles)

    memberships = Ash.read!(query, authorize?: false)

    by_workspace =
      Enum.group_by(memberships, & &1.workspace_id)
      |> Map.new(fn {workspace_id, [membership | _]} ->
        {workspace_id,
         %{
           my_membership_id: membership.id,
           my_role_names: Enum.map(membership.roles, &Atom.to_string(&1.name)),
           can_access: true
         }}
      end)

    key = Keyword.get(opts, :key, :my_role_names)

    Enum.map(records, fn workspace ->
      case Map.get(by_workspace, workspace.id) do
        nil ->
          default_for(key)

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

  defp default_for(:my_role_names), do: []
  defp default_for(:my_membership_id), do: nil
  defp default_for(:can_access), do: false
end
