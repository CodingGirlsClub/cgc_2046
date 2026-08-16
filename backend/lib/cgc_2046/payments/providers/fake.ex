defmodule Cgc2046.Payments.Providers.Fake do
  @moduledoc """
  测试/开发注入件（KTD3）：可脚本化的 FakeProvider。

  默认全成功形状；`script!/1` 覆盖指定回调的返回（迟到未付 / 金额不符 /
  退款失败等分支），`reset!/0` 恢复默认。脚本存进程字典（测试进程隔离），
  并发测试互不串扰。

  test.exs 经 `config :cgc_2046, :payments_providers` 注入本模块——生产路径
  的 WechatPay/Alipay adapter 不被测试触碰（渠道密钥零依赖）。
  """

  @behaviour Cgc2046.Payments.Provider

  @default_credential %{"type" => "jsapi", "pay_params" => %{"appId" => "wx-fake"}}

  @impl Cgc2046.Payments.Provider
  def create_payment(order, _ctx) do
    case scripted(:create_payment) do
      nil -> {:ok, Map.put(@default_credential, "out_trade_no", order.out_trade_no)}
      result -> result
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_transaction(out_trade_no) do
    case scripted(:fetch_transaction) do
      nil ->
        {:ok, %{status: :paid, amount_cents: 0, transaction_id: "fake-txn-" <> out_trade_no}}

      result ->
        result
    end
  end

  @impl Cgc2046.Payments.Provider
  def refund(_order) do
    case scripted(:refund) do
      nil -> :ok
      result -> result
    end
  end

  @impl Cgc2046.Payments.Provider
  def verify_webhook(raw_body, _headers) do
    case scripted(:verify_webhook) do
      nil ->
        case Jason.decode(raw_body) do
          {:ok, event} when is_map(event) -> {:ok, event}
          _ -> :error
        end

      result ->
        result
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_statement(_date) do
    case scripted(:fetch_statement) do
      nil -> {:ok, []}
      result -> result
    end
  end

  @doc "覆盖指定回调返回：script!(refund: {:error, :channel_rejected})"
  def script!(overrides) when is_list(overrides) do
    Enum.each(overrides, fn {callback, result} ->
      Process.put({__MODULE__, callback}, result)
    end)
  end

  @doc "恢复默认全成功形状。"
  def reset! do
    :erlang.process_info(self(), :dictionary)
    |> elem(1)
    |> Enum.each(fn {key, _} ->
      case key do
        {__MODULE__, _callback} -> :erlang.erase(key)
        _ -> :ok
      end
    end)
  end

  defp scripted(callback) do
    Process.get({__MODULE__, callback})
  end
end
