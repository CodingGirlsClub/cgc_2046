defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ClaimFirst do
  @moduledoc "claim_first 策略测试订阅方：向测试进程报告被调用。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.claim_first"],
    idempotency: :claim_first

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
