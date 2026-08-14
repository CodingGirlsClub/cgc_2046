defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ClaimAfter do
  @moduledoc "claim_after_effects 策略测试订阅方：可注入失败，成功才 claim。"

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.claim_after"],
    idempotency: :claim_after_effects

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"fail" => true} = data) do
    send(data["test_pid"], {:failed_effect, data["n"]})
    {:error, :boom}
  end

  def handle(_type, data) do
    send(data["test_pid"], {:handled, data["n"]})
    :ok
  end
end
