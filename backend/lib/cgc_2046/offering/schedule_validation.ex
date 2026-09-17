defmodule Cgc2046.Offering.ScheduleValidation do
  @moduledoc """
  `starts_at`/`ends_at` 时序校验（Ash Resource.Validation，KTD6）。

  两值同时存在时结束须严格晚于开始；只填一个合法；start 在过去合法
  （历史活动可录入）。message-only，不加 domain_error_code
  （sponsorship_tier.ex 同款先例，不触发错误码契约再生成）。

  #680：错误以显式 `InvalidAttribute.exception(value: ...)` 返回并回显实际起止
  时间——Ash 的 keyword 错误转换会无条件带 `value: nil`，MCP 出口折叠后渲染
  `Value: nil`，误导 agent 以为服务端把时间读成了 nil。
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
    ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :ends_at,
         message: "ends_at must be after starts_at",
         value: %{
           "starts_at" => DateTime.to_iso8601(starts_at),
           "ends_at" => DateTime.to_iso8601(ends_at)
         }
       )}
    else
      :ok
    end
  end
end
