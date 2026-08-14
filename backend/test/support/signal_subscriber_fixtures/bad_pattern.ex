defmodule Cgc2046.Workflows.SignalSubscriberFixtures.BadPattern do
  @moduledoc """
  订阅失败即停测试订阅方：路由校验拒绝（连续点）→ JidoAdapter.subscribe 返回
  {:error, _} → init {:stop, reason}（Q3）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture..bad"],
    idempotency: :state_based

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, _data), do: :ok
end
