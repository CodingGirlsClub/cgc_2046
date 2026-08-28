defmodule Cgc2046.Offering.EnrollmentBadge do
  @moduledoc """
  报名状态派生标签的纯函数（R6 / KTD1）。

  公开面只暴露派生标签，不暴露原始名额计数（capacity/confirmed_count 留在
  field_policy denylist）。枚举 `enrolling | starting_soon | closed | full`，优先级
  full > closed > starting_soon > enrolling：

  - capacity 非空且 confirmed_count >= capacity → `:full`
  - registration_deadline 已到或已过 → `:closed`
  - starts_at 落在未来 7 天内且报名未截止（registration_deadline 为空或
    晚于 now）→ `:starting_soon`
  - 其余 → `:enrolling`；无 starts_at 的条目永不为 `:starting_soon`

  Event/Course 的 `enrollment_badge` calculation 共用它（available_price_tiers
  委托 PriceTier 同款先例）。
  """

  @starting_soon_window_seconds 7 * 86_400

  @doc "由 offering 字段派生标签（now 注入：批量计算与测试共用同一时刻）。"
  @spec badge(
          %{
            capacity: integer() | nil,
            confirmed_count: integer(),
            starts_at: DateTime.t() | nil,
            registration_deadline: DateTime.t() | nil
          },
          DateTime.t()
        ) :: :enrolling | :starting_soon | :closed | :full
  def badge(offering, now) do
    cond do
      full?(offering) -> :full
      closed?(offering, now) -> :closed
      starting_soon?(offering.starts_at, now) -> :starting_soon
      true -> :enrolling
    end
  end

  defp full?(%{capacity: capacity, confirmed_count: confirmed_count}) do
    is_integer(capacity) and confirmed_count >= capacity
  end

  defp closed?(%{registration_deadline: nil}, _now), do: false

  defp closed?(%{registration_deadline: deadline}, now) do
    DateTime.compare(deadline, now) != :gt
  end

  defp starting_soon?(nil, _now), do: false

  defp starting_soon?(starts_at, now) do
    DateTime.compare(starts_at, now) == :gt and
      DateTime.compare(starts_at, DateTime.add(now, @starting_soon_window_seconds, :second)) !=
        :gt
  end
end
