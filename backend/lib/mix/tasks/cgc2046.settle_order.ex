defmodule Mix.Tasks.Cgc2046.SettleOrder do
  @shortdoc "Replay settlement for one order by out_trade_no (query-driven, idempotent)"

  @moduledoc """
  单笔订单落账收敛（webhook 丢失兜底）——`Cgc2046.Payments.ReplaySettlement`
  的 mix 薄封装，核心语义与幂等见该模块 moduledoc。

  生产容器内没有 mix；release 环境用：

      bin/cgc_2046 eval 'Cgc2046.Payments.ReplaySettlement.run("CGC…")'

  ## 用法

      mix cgc2046.settle_order CGC57637d09607a419ca713a769fc327

  仅入队（Oban 异步消费，秒级）；订单状态以 DB / 订单页为准。
  """

  use Mix.Task

  alias Cgc2046.Payments.ReplaySettlement

  @impl true
  def run([out_trade_no]) do
    {:ok, _} = Application.ensure_all_started(:cgc_2046)

    case ReplaySettlement.run(out_trade_no) do
      {:ok, %{event_id: event_id, job_id: job_id}} ->
        Mix.shell().info("enqueued settlement: event=#{event_id} job=#{job_id}")

      {:error, :order_not_found} ->
        Mix.shell().error("order not found: #{out_trade_no}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("settlement enqueue failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_), do: Mix.raise("usage: mix cgc2046.settle_order <out_trade_no>")
end
