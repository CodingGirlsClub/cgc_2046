defmodule Cgc2046.Events.PaymentModeValidation do
  @moduledoc """
  缴费模式三态互斥校验（Event 押金制 KTD3 / R1 / R3，AE1）。

  免费 / 定价档位 / 押金三态互斥；`deposit_enabled` 与 `pricing_enabled`
  不可同真；押金开启时 `deposit_amount_cents` 必须为正整数且 `ends_at`
  非空（no-show 结算锚点，KTD7）。拒绝时抛稳定 `BusinessError` code
  （#241 契约），前端按 code 查文案表。

  并发兜底（两编辑各基于旧值通过资源校验）由 DB CHECK
  `events_payment_mode_exclusive` 承担，经 `Event.handle_write_error/2`
  映射回同一稳定 code。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Errors.BusinessError

  @impl true
  def validate(changeset, _opts, _context) do
    deposit_enabled = Ash.Changeset.get_attribute(changeset, :deposit_enabled)
    pricing_enabled = Ash.Changeset.get_attribute(changeset, :pricing_enabled)

    cond do
      # 互斥是无条件不变量（DB CHECK 同款）：任何写入都拦
      deposit_enabled == true and pricing_enabled == true ->
        {:error, domain_error(:payment_mode_exclusive, :deposit_enabled)}

      # 配置完整性只在**写入押金相关字段**时要求：存量行（押金已开但 ends_at 为
      # 空的旧数据）不能被无关编辑（改标题/描述）永久锁死。这类行由
      # DepositForfeitWorker 的 deposit_settlement_unanchored Finding 暴露。
      deposit_enabled == true and deposit_config_touched?(changeset) and
          not positive_integer?(amount(changeset)) ->
        {:error, domain_error(:deposit_amount_required, :deposit_amount_cents)}

      deposit_enabled == true and deposit_config_touched?(changeset) and
          is_nil(Ash.Changeset.get_attribute(changeset, :ends_at)) ->
        {:error, domain_error(:deposit_ends_at_required, :ends_at)}

      # ends_at 是 no-show 结算的资金扳机（KTD7）：存在未终态押金单时禁止前移
      # ——否则把 ends_at 改到 48h 前即触发下一拍全量不可逆没收（adversarial P1）
      deposit_enabled == true and ends_at_moved_earlier?(changeset) and
          not offering_matches?(changeset) ->
        {:error,
         Cgc2046.Errors.BusinessError.exception(
           message: "cannot move ends_at earlier while active deposit orders exist",
           code: "event_ends_at_frozen",
           fields: [:ends_at]
         )}

      true ->
        :ok
    end
  end

  defp deposit_config_touched?(changeset) do
    Enum.any?([:deposit_enabled, :deposit_amount_cents, :ends_at], fn attribute ->
      Ash.Changeset.changing_attribute?(changeset, attribute)
    end)
  end

  # ends_at 前移 = 新值 < 旧值
  defp ends_at_moved_earlier?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :ends_at) and
      not is_nil(Ash.Changeset.get_data(changeset, :ends_at)) and
      not is_nil(Ash.Changeset.get_attribute(changeset, :ends_at)) and
      DateTime.compare(
        Ash.Changeset.get_attribute(changeset, :ends_at),
        Ash.Changeset.get_data(changeset, :ends_at)
      ) == :lt
  end

  # 有无非终态押金单（paid/refunding/refund_failed）→ 冻结守卫的触发条件。
  # 跨域只读（Events → Payments Order），单次点查（Event update 低频）。
  defp offering_matches?(changeset) do
    event_id = Ash.Changeset.get_data(changeset, :id)

    case Cgc2046.Repo.query(
           """
           SELECT 1 FROM payments_orders
           WHERE enrollment_id IN (SELECT id FROM enrollments WHERE event_id = $1)
             AND order_kind = 'deposit'
             AND status IN ('paid', 'refunding', 'refund_failed')
           LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: []}} -> true
      {:ok, %{rows: [_ | _]}} -> false
      _ -> false
    end
  end

  defp amount(changeset), do: Ash.Changeset.get_attribute(changeset, :deposit_amount_cents)

  defp positive_integer?(amount), do: is_integer(amount) and amount > 0

  @doc """
  押金×定价互斥的稳定业务错误（KTD3 单源）。

  Event 校验（本模块 validate/3）与 DB CHECK 兜底（Event.handle_write_error/2）
  共用同一 message 与 code；`check_constraint` DSL 的 `message:` 是编译期字面量、
  无法引用本函数，故那边保留同文字面量并注释互指。
  """
  def exclusive_error(field), do: domain_error(:payment_mode_exclusive, field)

  defp domain_error(reason, field) do
    BusinessError.exception(
      message: domain_error_message(reason),
      code: domain_error_code(reason),
      fields: [field]
    )
  end

  defp domain_error_message(:payment_mode_exclusive),
    do: "an event cannot enable both pricing tiers and deposit"

  defp domain_error_message(:deposit_amount_required),
    do: "a positive deposit_amount_cents is required when deposit is enabled"

  defp domain_error_message(:deposit_ends_at_required),
    do: "ends_at is required when deposit is enabled (settlement anchor)"

  # 显式子句化（#241）：字面量 code 进错误码契约工件，前端文案表按 code 查
  defp domain_error_code(:payment_mode_exclusive), do: "event_payment_mode_exclusive"
  defp domain_error_code(:deposit_amount_required), do: "event_deposit_amount_required"
  defp domain_error_code(:deposit_ends_at_required), do: "event_deposit_ends_at_required"
end
