defmodule Mix.Tasks.Cgc2046.DevPay do
  @moduledoc """
  dev 专用：把一笔 pending 订单推到 paid（story 3.12）。

      mix cgc2046.dev_pay <out_trade_no>

  走与真实 webhook 相同的链路：写入 `webhook_events` → Oban
  `PaymentSettlementWorker` → `DevFake.fetch_transaction/1` 回查订单金额 →
  订单 CAS paid → 报名 settling paid。仅当 dev 配置注入
  `Providers.DevFake` 时可用（其他环境无此 provider，任务拒绝执行）。
  """

  use Mix.Task

  require Ash.Query

  alias Cgc2046.Payments.{Order, Provider, WebhookEvent}
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker

  @shortdoc "dev: settle a pending order to paid via DevFake"

  @impl Mix.Task
  def run([out_trade_no]) do
    Mix.Task.run("app.start")
    ensure_dev_fake!()

    order =
      case Order
           |> Ash.Query.filter(out_trade_no == ^out_trade_no)
           |> Ash.read_one(authorize?: false) do
        {:ok, %Order{} = order} -> order
        {:ok, nil} -> Mix.raise("order not found for out_trade_no=#{out_trade_no}")
        {:error, reason} -> Mix.raise("order lookup failed: #{inspect(reason)}")
      end

    event_id = "dev-" <> Ecto.UUID.generate()

    payload = %{
      "id" => event_id,
      "out_trade_no" => out_trade_no,
      "amount_cents" => order.amount_cents,
      "transaction_id" => "dev-fake-" <> out_trade_no
    }

    {:ok, webhook_event} =
      WebhookEvent
      |> Ash.Changeset.for_create(:create, %{
        provider: Provider.channel_of(order.provider),
        event_id: event_id,
        payload: payload
      })
      |> Ash.create(authorize?: false)

    # dev 任务同步执行落账 worker（不依赖 Oban 队列/进程生命周期）：
    # 与 webhook 链路执行同一个 worker 与同一套 CAS，结果确定可观察。
    result =
      PaymentSettlementWorker.perform(%Oban.Job{
        args: %{"webhook_event_id" => webhook_event.id}
      })

    reloaded = Ash.get!(Order, order.id, authorize?: false)

    Mix.shell().info(
      "order #{out_trade_no} status=#{reloaded.status} amount_cents=#{reloaded.amount_cents} worker=#{inspect(result)}"
    )
  end

  def run(_args) do
    Mix.raise("usage: mix cgc2046.dev_pay <out_trade_no>")
  end

  defp ensure_dev_fake! do
    providers = Application.get_env(:cgc_2046, :payments_providers, %{})

    unless providers[:wechat] == Cgc2046.Payments.Providers.DevFake do
      Mix.raise(
        "payments_providers is not DevFake; run with dev config (MIX_ENV=dev) and the dev.exs injection"
      )
    end
  end
end
