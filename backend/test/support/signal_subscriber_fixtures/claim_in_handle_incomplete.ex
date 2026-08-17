defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ClaimInHandleIncomplete do
  @moduledoc """
  claim_in_handle 策略测试订阅方（G 方向②「未实现回调 raise」用例）：声明
  `idempotency: :claim_in_handle` 但只实现 `handle/2`、未实现 `before_claim/2`
  与 `effects/3`——骨架应 `raise ArgumentError`（编程错误，不做静默降级）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.claim_in_handle_incomplete"],
    idempotency: :claim_in_handle

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
