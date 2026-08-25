defmodule Cgc2046.Payments.ReplaySettlement do
  @moduledoc """
  单笔订单落账收敛（webhook 丢失兜底；生产实证 2026-08-25 建立）。

  ## 背景

  微信回调链路曾因 APIv3 密钥不匹配在解密段崩溃（verify_webhook → 500），
  渠道重试全数失败后事件永不落库——订单停在 pending、enrollment 停在
  payment_pending，而用户已真实扣款。本模块提供「造事件 + 入队」的收敛入口：
  payload 只带 out_trade_no，PaymentSettlementWorker 自查单取渠道权威状态
  （fetch_transaction），走标准落账链 mark_paid → settle_paid → 通知——
  不绕过任何状态机 CAS，金额不符/未支付等异常由 worker 既有分支处理。

  ## 幂等

  event_id = "replay-\<out_trade_no\>"，(provider, event_id) 唯一索引天然去重
  （重复 run 复用已存事件再入队，worker 全链 CAS 只收敛一次——语义同渠道
  重复投递，R21）。

  ## 执行面

  - dev/test：`mix cgc2046.settle_order <out_trade_no>`（薄封装本模块）。
  - 生产：`bin/cgc_2046 eval "Cgc2046.Payments.ReplaySettlement.run(\"…\")"`
    （PHX_SERVER 未设时 Endpoint 不监听，Oban 随 app 起并立即消费）。
  """

  require Ash.Query

  alias Cgc2046.Payments.Provider
  alias Cgc2046.Payments.{Order, WebhookEvent}
  alias Cgc2046.Workers.PaymentSettlementWorker

  @doc """
  按商户单号收敛落账。返回 `{:ok, %{event_id: …, job_id: …}}`；订单不存在
  返回 `{:error, :order_not_found}`（渠道侧无此单时无从收敛，先查单核实）。
  """
  def run(out_trade_no) when is_binary(out_trade_no) do
    with {:ok, order} <- fetch_order(out_trade_no) do
      event = ensure_event(order)

      case Oban.insert(PaymentSettlementWorker.new(%{"webhook_event_id" => event.id})) do
        {:ok, job} ->
          {:ok, %{event_id: event.id, job_id: job.id}}

        {:error, reason} ->
          {:error, {:enqueue_failed, reason}}
      end
    end
  end

  defp fetch_order(out_trade_no) do
    case Order
         |> Ash.Query.filter(out_trade_no == ^out_trade_no)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  # 复用已存 replay 事件（同单重复 run / 上次 run 后事件已落但 job 未入队）；
  # worker 侧幂等由状态机 CAS 保证，无需在此区分首次/重放。
  defp ensure_event(order) do
    event_id = "replay-" <> order.out_trade_no
    channel = Provider.channel_of(order.provider)

    WebhookEvent
    |> Ash.Query.filter(provider == ^channel and event_id == ^event_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        WebhookEvent
        |> Ash.Changeset.for_create(:create, %{
          provider: channel,
          event_id: event_id,
          payload: %{"out_trade_no" => order.out_trade_no}
        })
        |> Ash.create!(authorize?: false)

      {:ok, existing} ->
        existing
    end
  end
end
