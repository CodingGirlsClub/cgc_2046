defmodule Cgc2046.Workflows.SignalSubscriberFixtures.BusRestart do
  @moduledoc """
  bus 重启重订阅测试订阅方（#120）：双 pattern + state_based（无 claim——
  kill 后重投不因幂等键拦截），向测试进程报告投递。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.bus_restart", "fixture.bus_restart.extra"],
    idempotency: :state_based

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(type, %{"test_pid" => test_pid, "n" => n}) do
    send(test_pid, {:handled, type, n})
    :ok
  end
end
