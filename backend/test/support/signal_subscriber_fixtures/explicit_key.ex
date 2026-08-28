defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ExplicitKey do
  @moduledoc "consumer_key 显式声明测试订阅方（Fable 5 M3）：键值刻意异于 leaf 派生（explicit_key），证显式优先。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.explicit_key"],
    idempotency: :claim_first,
    consumer_key: "pinned_consumer"

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
