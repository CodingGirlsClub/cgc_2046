defmodule Cgc2046.Payments.Provider do
  @moduledoc """
  支付渠道边界 behaviour（KTD3，session-settled：chosen over 直接 mock SDK 层——
  微信/支付宝接口形状不同，adapter + fake 的测试面更小）。

  五个回调覆盖收款闭环全部渠道交互：

  - `create_payment/2`：下单，返回前端凭据（形状按 provider 分派，见各 adapter）。
  - `fetch_transaction/1`：查单（回调落账回查 / 退款兜底查单共用，R7/R9/U9）。
  - `refund/1`：退款。返回 `:ok` = 受理成功、完成以回调/查单为准（微信异步）；
    `{:ok, :completed}` = 同步完成、无需再查单收敛（支付宝同步语义——其查单
    trade_status 无退款终态枚举，完成信号只能在退款响应内给出）。微信/支付宝
    差异在 adapter 内吸收（R17/KTD17）。
  - `verify_webhook/2`：回调验签 + 资源解密（R21 入口段）。
  - `fetch_statement/1`：对账单拉取（规⑦，U13）。

  渠道密钥按 KTD7 从应用环境读取（runtime.exs 环境变量块，SendCloud 同款），
  密钥缺失时 adapter 返回 {:error, :provider_not_configured}，不静默外呼。

  ## 凭据形状（前端分派契约，U11/U12）

  - 微信 JSAPI：`%{"type" => "jsapi", "pay_params" => %{appId/timeStamp/nonceStr/package/signType/paySign}}`
  - 微信 Native：`%{"type" => "qr_code", "code_url" => "..."}`
  - 支付宝 page/wap：`%{"type" => "redirect", "url" => "..."}`

  ## 查单状态归一

  渠道侧状态统一归一为 `:paid | :pending | :closed | :refunded`（金额一律分，
  R20；transaction_id 为渠道交易号）。
  """

  @type order :: Cgc2046.Payments.Order.t()
  @type credential :: map()
  @type transaction :: %{
          required(:status) => :paid | :pending | :closed | :refunded,
          required(:amount_cents) => non_neg_integer(),
          required(:transaction_id) => String.t()
        }
  @type channel :: :wechat | :alipay
  @type provider_atom :: :wechat_jsapi | :wechat_native | :alipay_page | :alipay_wap | :alipay_qr

  @callback create_payment(order, ctx :: %{optional(:openid) => String.t()}) ::
              {:ok, credential} | {:error, term()}

  @callback fetch_transaction(out_trade_no :: String.t()) ::
              {:ok, transaction} | {:error, term()}

  @callback refund(order) :: :ok | {:ok, :completed} | {:error, term()}

  @callback verify_webhook(raw_body :: binary(), headers :: %{optional(String.t()) => String.t()}) ::
              {:ok, event :: map()} | :error

  @callback fetch_statement(date :: Date.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  provider 原子 → adapter 模块。四 provider 归属两渠道；测试/开发环境经
  `config :cgc_2046, :payments_providers` 注入 Fake（test.exs 已注入）。
  """
  @spec for(provider_atom()) :: module()
  def for(:wechat_jsapi), do: channel_adapter(:wechat)
  def for(:wechat_native), do: channel_adapter(:wechat)
  def for(:alipay_page), do: channel_adapter(:alipay)
  def for(:alipay_wap), do: channel_adapter(:alipay)
  def for(:alipay_qr), do: channel_adapter(:alipay)

  @doc """
  provider 原子 → 渠道原子（:wechat | :alipay）。WebhookEvent.provider 等
  渠道面字段消费（订单侧存的是完整 provider 枚举）。
  """
  @spec channel_of(provider_atom()) :: channel()
  def channel_of(:wechat_jsapi), do: :wechat
  def channel_of(:wechat_native), do: :wechat
  def channel_of(:alipay_page), do: :alipay
  def channel_of(:alipay_wap), do: :alipay
  def channel_of(:alipay_qr), do: :alipay

  @doc "渠道原子（:wechat | :alipay）→ adapter 模块（回调入口消费）。"
  @spec for_channel(channel()) :: module()
  def for_channel(channel), do: channel_adapter(channel)

  defp channel_adapter(channel) do
    default = %{
      wechat: Cgc2046.Payments.Providers.WechatPay,
      alipay: Cgc2046.Payments.Providers.Alipay
    }

    Application.get_env(:cgc_2046, :payments_providers, default)
    |> Map.fetch!(channel)
  end
end
