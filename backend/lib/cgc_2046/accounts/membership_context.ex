defmodule Cgc2046.Accounts.MembershipContext do
  @moduledoc """
  「actor ↔ 工作台」成员资格数据读取的唯一归属（#2 成员资格读取收敛）。

  ## 职责

  持有全部成员资格读取形状（`WorkspaceMembership` + `load(:roles)`），供
  Rbac 判定、WorkspaceActorIsOwnerOrAdmin policy、CurrentMembershipInfo 计算字段
  委托。判定语义（roles_can? / abilities_for）不在本模块 —— 那是 Rbac 的职责；
  角色名字符串化也不在本模块 —— 那是 GraphQL 边缘（CurrentMembershipInfo）的职责。

  ## 成员资格上下文（术语）

  见 CONTEXT.md「成员资格上下文」：actor 在目标工作台（租户）的成员资格及角色
  名字（原子列表）的读取面；`role_names/2` 为 Rbac.role_names/2 的同名委托目标，
  读取实现唯一归属本模块。

  ## 错误姿态（与收敛前一致）

  - `membership_of/2`：读失败返回 `nil`（Rbac 旧行为）
  - `memberships_of_actor/1`：读失败直接抛出（CurrentMembershipInfo 旧行为，read!）
  - `owner_count/1`：读失败直接抛出（BypassReads 委托，与 member_count/1 一致）

  内部均 `authorize?: false`（读取面不做鉴权，鉴权由调用方判定语义负责）。

  ## 为什么收在这里

  Ash 升级（filter struct 形状变化）只炸本模块 + `resolve_workspace_id/1` 钉测
  （membership_context_test.exs），一处炸、一处改。
  """

  require Ash.Query

  alias Cgc2046.Accounts.BypassReads
  alias Cgc2046.Accounts.WorkspaceMembership

  @doc """
  返回 actor 在目标工作台的成员资格（roles 已加载），非成员 / 匿名 / 读失败返回 `nil`。
  """
  @spec membership_of(term, String.t()) :: WorkspaceMembership.t() | nil
  def membership_of(nil, _workspace_id), do: nil

  def membership_of(actor, workspace_id) do
    case Ash.read(actor_memberships_query(actor), authorize?: false, tenant: workspace_id) do
      {:ok, [membership | _]} -> membership
      _ -> nil
    end
  end

  @doc """
  返回 actor 在目标工作台的角色名列表（多角色并集，按 membership.roles 加载顺序）。

  - actor 只需含 `:id` 字段（assign_roles grant scope 校验可用 `%{id: user_id}` map 传 target）
  - 非成员 / 匿名返回 `[]`
  """
  @spec role_names(term, String.t()) :: [atom]
  def role_names(actor, workspace_id) do
    case membership_of(actor, workspace_id) do
      nil -> []
      membership -> Enum.map(membership.roles, & &1.name)
    end
  end

  @doc """
  返回 actor 的全部成员资格（跨租户 global 读，roles 已加载）。

  供 CurrentMembershipInfo 计算字段按 workspace_id 分组使用；读失败抛出
  （read!，与计算字段旧行为一致）。
  """
  @spec memberships_of_actor(term) :: [WorkspaceMembership.t()]
  def memberships_of_actor(actor) do
    Ash.read!(actor_memberships_query(actor), authorize?: false)
  end

  @doc """
  返回目标工作台当前持有 owner 角色的成员数（按 membership 去重，一人多角色只算 1 次）。

  委托 BypassReads.owner_count/1（raw COUNT，不经 membership read policy）。
  DB 失败直接抛（与 member_count/1 一致；不再吞错返 0）。
  """
  @spec owner_count(String.t()) :: non_neg_integer
  def owner_count(workspace_id), do: BypassReads.owner_count(workspace_id)

  @doc """
  从 policy context 解析目标工作台 id（#2 AST 提取收拢，三场景行为与收敛前一致）。

  ## 场景

  1. changeset（update / assign_roles）：`changeset.tenant` 或 changeset 上的 workspace_id
  2. list query（成员列表）：tenant 可能为空（global 查询），从 filter 提取 workspace_id
  3. get-by-id（GraphQL update mutation 先读目标记录）：filter 只有 id，
     按 id 读出记录后再取 workspace_id
  4. changeset 目标即 Workspace 资源自身（#78 update_workspace）：Workspace 无
     workspace_id 属性，目标工作台 = 被更新记录本身（data.id / attributes.id）

  ## Ash 版本钉点

  Ash 3.31 的 filter 表达式是 struct（如 `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}}`），
  不是 tuple AST，提取时需按 struct 匹配 —— 见 membership_context_test.exs 的
  resolve_workspace_id 钉测（用真实 Ash.Query 生成的 filter 断言，Ash 升级改 struct
  形状时测试当场失败，指明唯一需要改动的模块）。
  """
  @spec resolve_workspace_id(map) :: String.t() | nil
  def resolve_workspace_id(%{changeset: %Ash.Changeset{} = changeset}) do
    changeset.tenant || changeset_workspace_id(changeset)
  end

  def resolve_workspace_id(%{query: %Ash.Query{} = query}) do
    query.tenant ||
      filter_workspace_id(query.filter) ||
      workspace_id_by_id_filter(query.filter)
  end

  def resolve_workspace_id(_), do: nil

  # update/bulk 场景 changeset.data 可能为 nil，先保护再取
  defp changeset_workspace_id(changeset) do
    if changeset.data do
      Ash.Changeset.get_attribute(changeset, :workspace_id) ||
        workspace_self_id(changeset)
    else
      Map.get(changeset.attributes, :workspace_id) || workspace_self_id(changeset)
    end
  end

  # #78：目标资源即 Workspace 时，工作台 id = 被更新记录自身 id（data 可能为 nil，
  # 回退 attributes）。仅限 Workspace 资源 —— 其它租户资源的 data.id 是记录自身
  # 主键（如 membership id），不能误当作 workspace_id。
  defp workspace_self_id(%Ash.Changeset{resource: Cgc2046.Accounts.Workspace} = changeset) do
    if changeset.data do
      Ash.Changeset.get_attribute(changeset, :id)
    else
      Map.get(changeset.attributes, :id)
    end
  end

  defp workspace_self_id(_changeset), do: nil

  # actor 成员资格查询形状的唯一实现（membership_of / memberships_of_actor 共用）
  defp actor_memberships_query(actor) do
    WorkspaceMembership
    |> Ash.Query.filter(user_id == ^actor.id)
    |> Ash.Query.load(:roles)
  end

  # -- filter 提取 -----------------------------------------------------------

  # 成员列表 filter（如 GraphQL workspaceId: { eq: "..." }）生成
  # `%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{name: :workspace_id}, right: value}`
  defp filter_workspace_id(%Ash.Filter{expression: expression}) do
    workspace_id_from_expr(expression)
  end

  defp filter_workspace_id(_), do: nil

  defp workspace_id_from_expr(%Ash.Query.Operator.Eq{left: left, right: right}) do
    cond do
      workspace_id_ref?(left) -> value_of(right)
      workspace_id_ref?(right) -> value_of(left)
      true -> nil
    end
  end

  defp workspace_id_from_expr(%Ash.Query.BooleanExpression{
         op: op,
         left: left,
         right: right
       })
       when op in [:and, :or] do
    workspace_id_from_expr(left) || workspace_id_from_expr(right)
  end

  defp workspace_id_from_expr(_), do: nil

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
end
