defmodule Cgc2046.Payments.Providers.DevFake do
  @moduledoc """
  dev 专用 Fake 支付渠道（story 3.12）——让本地/真机在 dev 环境也能把订单
  从 `pending` 推到 `paid`，且结算金额与订单金额相等。

  与 `Providers.Fake`（test.exs 注入、进程字典脚本、默认金额 0）的区别：

  - `create_payment/2` 返回 `qr_code` 凭据（`code_url`），客户端可直接渲染二维码；
  - `fetch_transaction/1` 按 `out_trade_no` 回查本地订单，返回该订单的
    `amount_cents`，因此结算链条的金额校验（R20）能真实通过；
  - `verify_webhook/2` 直接解 JSON（dev 无签名），配合
    `mix cgc2046.dev_pay <out_trade_no>` 触发真实 webhook 落账链路。

  **只用于 dev**：生产/测试配置不注入本模块（dev.exs 单独覆盖
  `:payments_providers`）。禁止用它替代真实渠道验收。
  """

  @behaviour Cgc2046.Payments.Provider

  require Ash.Query

  alias Cgc2046.Payments.Order

  @impl Cgc2046.Payments.Provider
  def create_payment(order, _ctx) do
    {:ok,
     %{
       "type" => "qr_code",
       "code_url" => "https://dev.cgc2046.local/pay/#{order.out_trade_no}",
       "out_trade_no" => order.out_trade_no,
       "amount_cents" => order.amount_cents
     }}
  end

  @impl Cgc2046.Payments.Provider
  def fetch_transaction(out_trade_no) do
    case Order
         |> Ash.Query.filter(out_trade_no == ^out_trade_no)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        {:error, :order_not_found}

      {:ok, order} ->
        {:ok,
         %{
           status: :paid,
           amount_cents: order.amount_cents,
           transaction_id: "dev-fake-" <> out_trade_no
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Cgc2046.Payments.Provider
  def refund(_order), do: {:ok, :completed}

  @impl Cgc2046.Payments.Provider
  def verify_webhook(raw_body, _headers) do
    case Jason.decode(raw_body) do
      {:ok, %{"out_trade_no" => out_trade_no} = event} when is_binary(out_trade_no) ->
        {:ok, event}

      _ ->
        :error
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_statement(_date), do: {:ok, []}
end
