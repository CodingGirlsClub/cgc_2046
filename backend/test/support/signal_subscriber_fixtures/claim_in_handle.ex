defmodule Cgc2046.Workflows.SignalSubscriberFixtures.ClaimInHandle do
  @moduledoc """
  claim_in_handle 策略测试订阅方（双回调形态，LI 语义缩影）：before_claim 校验
  （skip 注入）+ 骨架 claim + effects。重复投递由骨架归一化为 :ok（不重复执行
  effects）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["fixture.claim_in_handle"],
    idempotency: :claim_in_handle

  @impl Cgc2046.Workflows.SignalSubscriber

  # 校验不过（类比「无已发布学习定义 / 瞬时读失败」）：跳过，不 claim
  def before_claim(_type, %{"skip" => true} = data) do
    send(data["test_pid"], {:skipped, data["n"]})
    :skip
  end

  def before_claim(_type, data) do
    send(data["test_pid"], {:claimed, data["n"]})
    {:ok, data}
  end

  @impl Cgc2046.Workflows.SignalSubscriber
  def effects(_type, data, _ctx) do
    send(data["test_pid"], {:effects, data["n"]})
    :ok
  end
end
