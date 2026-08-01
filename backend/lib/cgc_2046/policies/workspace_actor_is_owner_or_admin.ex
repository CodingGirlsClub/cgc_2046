defmodule Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin do
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

  ## 注意

  Ash 3.31 的 filter 表达式是 struct（如 `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}`），
  不是 tuple AST，提取时需按 struct 匹配。
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias Cgc2046.Accounts.WorkspaceMembership

  @impl true
  def describe(_opts), do: "actor is owner or admin of the target workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    workspace_id =
      changeset.tenant ||
        safe_workspace_id(changeset)

    actor_manages_workspace?(actor, workspace_id)
  end

  # 查询场景（成员列表等）：tenant 可能为空（global 查询），
  # 从 filter 中提取 workspace_id 判断 actor 是否管理该工作台
  def match?(actor, %{query: %Ash.Query{} = query}, _opts) do
    workspace_id =
      query.tenant ||
        extract_workspace_id(query.filter) ||
        workspace_id_by_id_filter(query.filter)

    actor_manages_workspace?(actor, workspace_id)
  end

  def match?(_actor, _context, _opts), do: false

  # -- filter 提取 -----------------------------------------------------------

  # 成员列表 filter（如 GraphQL workspaceId: { eq: "..." }）生成
  # `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{name: :workspace_id}, right: value}`
  defp extract_workspace_id(%Ash.Filter{expression: expression}) do
    extract_workspace_id_from_expr(expression)
  end

  defp extract_workspace_id(_), do: nil

  defp extract_workspace_id_from_expr(%Ash.Query.Operator.Eq{left: left, right: right}) do
    cond do
      workspace_id_ref?(left) -> value_of(right)
      workspace_id_ref?(right) -> value_of(left)
      true -> nil
    end
  end

  defp extract_workspace_id_from_expr(%Ash.Query.BooleanExpression{
         op: op,
         left: left,
         right: right
       })
       when op in [:and, :or] do
    extract_workspace_id_from_expr(left) || extract_workspace_id_from_expr(right)
  end

  defp extract_workspace_id_from_expr(_), do: nil

  defp workspace_id_ref?(%Ash.Query.Ref{attribute: %{name: :workspace_id}}), do: true
  defp workspace_id_ref?(_), do: false

  defp value_of(value) when is_binary(value), do: value
  defp value_of(_), do: nil

  # get-by-id 场景：filter 形如 `id == "xxx"`（GraphQL update mutation 先按 id 读目标记录），
  # 无 workspace_id 条件，按 id 读出记录后取其 workspace_id
  defp workspace_id_by_id_filter(%Ash.Filter{
         expression: %Ash.Query.Operator.Eq{
           left: %Ash.Query.Ref{attribute: %{name: :id}},
           right: id
         }
       })
       when is_binary(id) do
    case Ash.get(WorkspaceMembership, id, authorize?: false) do
      {:ok, membership} -> membership.workspace_id
      _ -> nil
    end
  end

  defp workspace_id_by_id_filter(_), do: nil

  # -- 辅助 ----------------------------------------------------------------

  # update/bulk 场景 changeset.data 可能为 nil，先保护再取
  defp safe_workspace_id(changeset) do
    if changeset.data do
      Ash.Changeset.get_attribute(changeset, :workspace_id)
    else
      Map.get(changeset.attributes, :workspace_id)
    end
  end

  defp actor_manages_workspace?(_actor, nil), do: false

  defp actor_manages_workspace?(actor, workspace_id) do
    query =
      WorkspaceMembership
      |> Ash.Query.filter(user_id == ^actor.id)
      |> Ash.Query.load(:roles)

    case Ash.read(query, actor: actor, authorize?: false, tenant: workspace_id) do
      {:ok, [membership | _]} ->
        Enum.any?(membership.roles, fn role -> role.name in [:owner, :admin] end)

      _ ->
        false
    end
  end
end
