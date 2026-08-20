defmodule Cgc2046.Workflows.SignalSubscriberFixtures.DrainClaim do
  @moduledoc """
  drain 截断闭合测试订阅方（#245）：claim_first + handle 内 sleep 300ms——
  拉长「claim 已落、effects 未完」的在途窗口，使旧 kill 行为可复现截断、
  drain 行为可证闭合（effects 恰一次落账）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.drain_claim"],
    idempotency: :claim_first

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"test_pid" => test_pid, "n" => n}) do
    Process.sleep(300)
    send(test_pid, {:handled, n})
    :ok
  end
end
