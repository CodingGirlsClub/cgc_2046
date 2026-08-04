defmodule Cgc2046.Accounts.Calculations.MemberCount do
  @moduledoc """
  P1-4 Workspace.memberCount：成员数量（SQL 批量 count）。

  为什么不用 `calculate(expr(count(memberships)))` / aggregate count：见
  BypassReads（旁路读取面）moduledoc —— 子查询会叠加 WorkspaceMembership
  read policy，计数被过滤成仅 actor 自己（SimpleCheck 在子查询取不到
  workspace_id）。本计算字段只做数据映射，SQL 在旁路读取面。
  """

  use Ash.Resource.Calculation

  alias Cgc2046.Accounts.BypassReads

  @impl true
  def calculate(records, _opts, _context) do
    ids = records |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    counts = BypassReads.member_count(ids)

    Enum.map(records, fn record ->
      case record.id do
        nil -> 0
        id -> Map.get(counts, id, 0)
      end
    end)
  end
end
