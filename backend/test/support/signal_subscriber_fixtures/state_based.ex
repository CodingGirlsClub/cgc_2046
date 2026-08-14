defmodule Cgc2046.Workflows.SignalSubscriberFixtures.StateBased do
  @moduledoc "state_based 策略测试订阅方：不写 claim，每次投递都执行。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.state_based"],
    idempotency: :state_based

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
