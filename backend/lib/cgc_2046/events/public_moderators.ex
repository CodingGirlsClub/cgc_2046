defmodule Cgc2046.Events.PublicModerators do
  @moduledoc """
  `publicModerators` 公开读面投影（#538）：event 主理人名单 → 公开详情页
  展示字段（display_name / member_number 最小集）的批量投影。

  只组装两个键，userId / email / phone 结构性不存在（非过滤排除）——
  display_name 是用户自设全局展示名，member_number 是平台确定性公开编号
  （moduledoc「前端仅展示」），公开展示语义均成立。行级授权由 Event read
  policy 把门：Event 行可读（匿名仅 open+public；归档场 ActorReadsOffering）
  才轮到本投影求值，投影本身不设状态门（closed/cancelled 照出，跟随现有
  投影口径）。

  排序 assigned_at asc + id asc 与管理面 `Moderators.list/3` 逐字一致——
  公开页与工作台两处口径锁死（#538 决策 D1）。
  """

  require Ash.Query

  alias Cgc2046.Events.EventModerator

  @doc """
  calculation 入口：events（可跨租户）→ 逐个投影数组。

  EventModerator `global?(true)`，按 event_id 单趟批量 IN 查询后内存分组，
  无 N+1。`authorize?: false` = BypassReads 旁路先例（数据为公开标识非敏感，
  与 #537 平铺 calculation 同款）；复用既有 `user_display_name` /
  `user_member_number` 平铺 calculation（LEFT JOIN + MemberNumber 单源）。
  """
  @spec project([%{id: String.t()}]) :: [list(map())]
  def project(records) do
    event_ids = records |> Enum.map(& &1.id) |> Enum.uniq()

    rows_by_event = moderators_by_event(event_ids)

    Enum.map(records, fn record -> Map.get(rows_by_event, record.id, []) end)
  end

  defp moderators_by_event([]), do: %{}

  defp moderators_by_event(event_ids) do
    EventModerator
    |> Ash.Query.filter(event_id in ^event_ids)
    |> Ash.Query.sort(assigned_at: :asc, id: :asc)
    |> Ash.Query.load([:user_display_name, :user_member_number])
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(
      & &1.event_id,
      &%{display_name: &1.user_display_name, member_number: &1.user_member_number}
    )
  end
end
