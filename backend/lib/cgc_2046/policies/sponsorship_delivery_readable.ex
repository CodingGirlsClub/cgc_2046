defmodule Cgc2046.Policies.SponsorshipDeliveryReadable do
  @moduledoc """
  履约账本行读取授权（E-3 #48）。

  交付行唯一的 GraphQL 暴露面是 Sponsorship.deliveries 关系字段（父行读取已授权）；
  关系加载的 query 上下文只带 sponsorship_id 过滤（无 tenant），
  WorkspaceActorIsOwnerOrAdmin 无法经 filter 解析工作台 → 本检查直接从
  filter 提取 sponsorship_id、读回 Sponsorship（authorize?: false）后判定：
  - sponsor 本人（同 Sponsorship read policy 第一分支）；
  - 目标工作台 Owner/Admin（同 Sponsorship read policy 第二分支）。

  父行已授权 → 此检查只把父行授权翻译到交付行，不扩大任何权限面。
  """

  use Ash.Policy.SimpleCheck

  alias Cgc2046.Accounts.{MembershipContext, Role}
  alias Cgc2046.Sponsorship.{Sponsorship, SponsorshipDelivery}

  @impl true
  def describe(_opts), do: "actor can read the parent sponsorship"

  @impl true
  def match?(nil, _context, _opts), do: false

  # 全部命中 id 可见才放行（评审 A2：Enum.any? 会把多 id 查询过近似授权——
  # 混合多个工作台的 filter 只要一个可见就放行全部）；空 filter 拒绝（无依据）。
  def match?(actor, %{query: %Ash.Query{} = query}, _opts) do
    case sponsorship_ids(query) do
      [] ->
        false

      ids ->
        Enum.all?(ids, &sponsorship_visible_to?(actor, &1))
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp sponsorship_visible_to?(actor, sponsorship_id) do
    case Ash.get(Sponsorship, sponsorship_id, authorize?: false) do
      {:ok, sponsorship} ->
        sponsorship.sponsor_user_id == actor.id or
          actor
          |> MembershipContext.role_names(sponsorship.workspace_id)
          |> Enum.any?(&Role.manage_role?/1)

      _ ->
        false
    end
  end

  defp sponsorship_ids(%Ash.Query{filter: nil}), do: []

  defp sponsorship_ids(%Ash.Query{filter: %{expression: expression}}) do
    collect_sponsorship_ids(expression)
  end

  defp collect_sponsorship_ids(%Ash.Query.Operator.Eq{left: left, right: right}) do
    cond do
      sponsorship_ref?(left) && is_binary(right) -> [right]
      sponsorship_ref?(right) && is_binary(left) -> [left]
      # GraphQL update 的预读取按 id == 过滤（无 sponsorship_id）：读回交付行
      # 取其 sponsorship_id（同 MembershipContext.workspace_id_by_id_filter 模式）
      id_ref?(left) && is_binary(right) -> delivery_sponsorship_id(right)
      id_ref?(right) && is_binary(left) -> delivery_sponsorship_id(left)
      true -> []
    end
  end

  # 关系加载的 in 过滤 right 侧是 MapSet（Ash 内部构造）
  defp collect_sponsorship_ids(%Ash.Query.Operator.In{left: left, right: right}) do
    if sponsorship_ref?(left) do
      case right do
        %MapSet{} = set -> set |> MapSet.to_list() |> Enum.filter(&is_binary/1)
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  end

  # AND/OR 布尔表达式（左/右递归）；必须放在具体算子子句之后（算子也是 map）
  defp collect_sponsorship_ids(%{left: left, right: right} = expression)
       when is_map(expression) do
    collect_sponsorship_ids(left) ++ collect_sponsorship_ids(right)
  end

  defp collect_sponsorship_ids(_), do: []

  defp delivery_sponsorship_id(delivery_id) do
    case Ash.get(SponsorshipDelivery, delivery_id, authorize?: false) do
      {:ok, %{sponsorship_id: sponsorship_id}} -> [sponsorship_id]
      _ -> []
    end
  end

  defp sponsorship_ref?(%Ash.Query.Ref{attribute: %{name: :sponsorship_id}}), do: true
  defp sponsorship_ref?(_), do: false

  defp id_ref?(%Ash.Query.Ref{attribute: %{name: :id}}), do: true
  defp id_ref?(_), do: false
end
