defmodule Cgc2046.Workers.PaymentSettlementWorker do
  @moduledoc """
  支付回调落账 worker（U6 入队 / U7 落账实现）。

  入口（KTD4）：webhook controller 验签后同事务入队，args 只带
  webhook_event_id + provider。落账唯一路径：回查渠道 → 金额校验 → CAS
  Order/Enrollment 状态机迁移 → 通知与信号（R7/R9/R20-R22）。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => event_id}}) do
    # U7 落账实现落位于此；事件已由入口幂等落库，此处读事件驱动状态机。
    _ = event_id
    Logger.info("payment settlement worker invoked (logic lands in U7)")
    :ok
  end

  def perform(%Oban.Job{}), do: :ok
end
