defmodule Cgc2046.Workflows.SignalSubscriberFixtures.Crash do
  @moduledoc "rescue 壳测试订阅方：可注入 raise。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.crash"],
    idempotency: :state_based

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"raise" => true}), do: raise("boom")

  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
