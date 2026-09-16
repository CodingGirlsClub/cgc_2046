defmodule Cgc2046.Mcp.Tools.PaymentSlot do
  @moduledoc """
  MCP 读面缴费槽投影（issue #586）：三态 `payment_mode`（free | pricing | deposit）
  与押金明细 `deposit` 的唯一出口，discover_offerings / get_enrollment_summary /
  get_public_offering / list_workspace_events 共用。

  三态判定不在这里——单源 = `Cgc2046.Offering.payment_mode/1`（域）；本模块只做
  **展示降级**：

  - `deposit.enabled` 只看 mode，不看金额：押金场金额脏（历史行的 nil / 0）也恒为
    `true`，绝不掉回「免费」——agent 把押金场说成免费的病根即「无信号 + 金额缺失」
    被读成免费。
  - `deposit.amount_cents` 只出正整数，否则 `nil`（判据同源
    `Offering.deposit_amount_cents/1` ↔ `Payments.Order.deposit_tier/1`），绝不显示
    `0`（小程序 `depositPayNotice` / web checkout 同款守卫）。
  - `refundable_on_check_in` 押金态恒 `true`：平台规则「到场核销即退」（CONTEXT
    押金段），非每场可配；其余态 `nil`。退改散文（「截止前取消全额退；截止后不退」）
    不在 DTO——那属 agent 端 playbook 文案。
  - 非押金场形状恒定（`enabled: false` 而非整块 `nil`）：字段缺席正是本 issue 的
    病根，恒定形状让「押金槽存在但未开」可见。
  """

  alias Cgc2046.Offering

  @doc """
  供给物 → `%{payment_mode: String.t(), deposit: map()}`（调用方 merge 进各自 DTO）。
  Event/Course struct 或 atom 键 map（含 `pricing_enabled`/`deposit_enabled`）皆可；
  **string 键 map（JSON 解码形状）会被谓词判成 free**（`Offering.payment_mode/1`
  只匹配 atom 键），调用方不得直传解码后的 payload。
  """
  @spec projection(map() | nil) :: %{payment_mode: String.t(), deposit: map()}
  def projection(offering) do
    mode = Offering.payment_mode(offering)

    %{payment_mode: to_string(mode), deposit: deposit_block(offering, mode)}
  end

  defp deposit_block(offering, :deposit) do
    %{
      enabled: true,
      amount_cents: Offering.deposit_amount_cents(offering),
      refundable_on_check_in: true
    }
  end

  defp deposit_block(_offering, _mode) do
    %{enabled: false, amount_cents: nil, refundable_on_check_in: nil}
  end
end
