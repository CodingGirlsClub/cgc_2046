defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ClaimInHandle do
  @moduledoc """
  claim_in_handle 策略测试订阅方（LI 语义缩影）：校验不过不烧 claim；
  校验通过才经骨架 claim/3 登记；重复投递归一化为 :ok。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.claim_in_handle"],
    idempotency: :claim_in_handle

  @impl Cgc2046.Workflows.SignalSubscriber

  # 校验不过（类比「无已发布学习定义 / 瞬时读失败」）：跳过，不 claim
  def handle(_type, %{"skip" => true} = data) do
    send(data["test_pid"], {:skipped, data["n"]})
    :ok
  end

  def handle(_type, data) do
    case Cgc2046.Workflows.SignalSubscriber.claim(__MODULE__, "fixture.claim_in_handle", data) do
      {:ok, _key} ->
        send(data["test_pid"], {:claimed, data["n"]})
        :ok

      :duplicate ->
        send(data["test_pid"], {:duplicate, data["n"]})
        :ok
    end
  end
end
