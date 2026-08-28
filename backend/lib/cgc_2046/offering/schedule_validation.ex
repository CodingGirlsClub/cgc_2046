defmodule Cgc2046.Offering.ScheduleValidation do
  @moduledoc """
  `starts_at`/`ends_at` 时序校验（Ash Resource.Validation，KTD6）。

  两值同时存在时结束须严格晚于开始；只填一个合法；start 在过去合法
  （历史活动可录入）。message-only，不加 domain_error_code
  （sponsorship_tier.ex 同款先例，不触发错误码契约再生成）。
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
    ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      {:error, field: :ends_at, message: "ends_at must be after starts_at"}
    else
      :ok
    end
  end
end
