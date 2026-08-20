defmodule Cgc2046.Workflows.SignalSubscriberFixtures.BusProbe do
  @moduledoc """
  bus 退避 give-up → 低频无限探测 → 恢复 测试订阅方（#244）：注入毫秒级小
  参数（max_retries 3 / probe_interval_ms 200）使 give-up→探测→恢复全链秒级
  完成。state_based（无 claim——bus 缺席期间重投不因幂等键拦截）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.bus_probe"],
    idempotency: :state_based,
    max_retries: 3,
    probe_interval_ms: 200

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"test_pid" => test_pid, "n" => n}) do
    send(test_pid, {:handled, n})
    :ok
  end
end
