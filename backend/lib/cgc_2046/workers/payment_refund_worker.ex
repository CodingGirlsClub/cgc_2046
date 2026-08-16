defmodule Cgc2046.Workers.PaymentRefundWorker do
  @moduledoc """
  退款渠道调用 worker（U7 入队 / U9 实现）。

  消费两类入队源：
  - U7 落账 worker 的自动退款（迟到扣款 AE2 / 免缴竞态 AE3——收款但无对应占位）；
  - U9 退款 action（管理员单笔 / Event cancelled 批量）。

  职责：调渠道退款 API → 按（回调/同步/查单兜底）结果推进 refunded /
  refund_failed + 报名取消 + 名额释放 + 通知（R15-R17，退款即取消 ADR-0007）。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) do
    _ = order_id
    Logger.info("payment refund worker invoked (logic lands in U9)")
    :ok
  end

  def perform(%Oban.Job{}), do: :ok
end
