defmodule Cgc2046.Events.Calculations.MemberNumberOf do
  @moduledoc """
  EventModerator 行的成员编号平铺（#537）：从 uuid 列（`opts[:field]` 指定，
  user_id / assigned_by）确定性现算，规则单源 `MemberNumber.from_uuid/1`。

  不用 `expr(user.member_number)`：module calculation 无法 SQL 平铺，Ash
  运行时计算反而要加载 user 关系（User read policy 滤空风险 + 额外查询）；
  编号本就是 uuid 前 6 hex 的纯函数，直接从本行列算，零 JOIN。
  """

  use Ash.Resource.Calculation

  alias Cgc2046.Accounts.Calculations.MemberNumber

  @impl true
  def calculate(records, opts, _context) do
    field = opts[:field]
    Enum.map(records, &MemberNumber.from_uuid(Map.get(&1, field)))
  end
end
