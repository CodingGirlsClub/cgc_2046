defmodule Cgc2046.Workflows.SignalSubscriberFixtures.Resubscribe do
  @moduledoc "DOWN 重订阅测试订阅方：handle 内自杀模拟 forwarder 崩溃（D3 场景）。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.resubscribe"],
    idempotency: :state_based

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    Process.exit(self(), :kill)
  end
end
