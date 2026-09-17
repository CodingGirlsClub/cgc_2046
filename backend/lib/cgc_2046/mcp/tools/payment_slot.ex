defmodule Cgc2046.Mcp.Tools.PaymentSlot do
  @moduledoc """
  MCP 读面缴费槽投影（issue #586）：三态 `payment_mode`（free | pricing | deposit）
  与押金明细 `deposit` 的出口，discover_offerings / get_enrollment_summary /
  get_public_offering / list_workspace_events 共用。

  形状与展示降级规则的**唯一实现已下沉到域层** `Cgc2046.Offering.payment_slot/1`
  （#627：公开 Initiative 投影也要同一形状，domain 不得反向依赖 interface 层）——
  本模块只是 MCP 面的命名入口，语义与降级规则见域层 @doc，此处不复制。

  三态判定同样不在本模块：单源 = `Cgc2046.Offering.payment_mode/1`。
  """

  alias Cgc2046.Offering

  @doc """
  供给物 → `%{payment_mode: String.t(), deposit: map()}`（调用方 merge 进各自 DTO）。
  委托 `Cgc2046.Offering.payment_slot/1`（形状与降级规则的唯一实现）。
  """
  @spec projection(map() | nil) :: %{payment_mode: String.t(), deposit: map()}
  def projection(offering), do: Offering.payment_slot(offering)
end
