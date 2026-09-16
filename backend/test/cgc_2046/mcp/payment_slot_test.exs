defmodule Cgc2046.Mcp.Tools.PaymentSlotTest do
  @moduledoc """
  #586 缴费槽读面投影：押金场金额脏（历史行的 nil / 0 / 负）时的展示降级。

  该脏态在 #608 / #623 三条押金锚点 DB CHECK 上线后**库内不可制造**（`NOT VALID`
  只对存量行豁免；生产普查 0 行、dev 0 行，见 `20260916170000` 迁移 moduledoc）。
  原先经 raw SQL 布置脏行的集成用例（`public_offering_tools_test` /
  `learner_journey_tools_test`）因此无法再构造该状态，降级判据在本层（纯函数）钉住：
  三态只看开关、金额非正/缺失只降级展示、落点预测绝不改判免费。存量回填 +
  `VALIDATE` 见 issue #634。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Mcp.Tools.PaymentSlot
  alias Cgc2046.Offering

  for amount <- [nil, 0, -1] do
    test "押金开 + 金额 #{inspect(amount)}：仍 deposit、amount_cents=nil，绝不免费 / 绝不 0" do
      dirty = %{
        deposit_enabled: true,
        pricing_enabled: false,
        deposit_amount_cents: unquote(amount)
      }

      assert Offering.payment_mode(dirty) == :deposit
      assert Offering.deposit_amount_cents(dirty) == nil

      assert PaymentSlot.projection(dirty) == %{
               payment_mode: "deposit",
               deposit: %{enabled: true, amount_cents: nil, refundable_on_check_in: true}
             }

      # 落点预测同源（Enrollment.auto_confirm_status/1 委托 Offering.payment_mode/1）：
      # 非免费 → payment_pending，脏金额不改判免费
      assert Enrollment.auto_confirm_status(dirty) == :payment_pending
    end
  end

  test "押金开 + 正金额：原样出金额（降级不误伤正常行）" do
    clean = %{deposit_enabled: true, pricing_enabled: false, deposit_amount_cents: 6900}

    assert PaymentSlot.projection(clean) == %{
             payment_mode: "deposit",
             deposit: %{enabled: true, amount_cents: 6900, refundable_on_check_in: true}
           }

    assert Enrollment.auto_confirm_status(clean) == :payment_pending
  end
end
