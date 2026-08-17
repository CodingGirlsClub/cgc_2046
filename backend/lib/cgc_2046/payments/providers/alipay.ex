defmodule Cgc2046.Payments.Providers.Alipay do
  @moduledoc """
  支付宝 adapter（KTD3/KTD7）。

  - client 为手写薄模块（不用 Alipay.ClientBuilder 宏——其在编译期固化密钥，
    与 KTD7 runtime 注入冲突）；`Alipay.Requester` 按请求读取 app_id/private_key。
  - 凭据形状：page/wap → 跳转 URL（`%{"type" => "redirect", "url" => ...}`）。
  - 退款同步返回：受理即知结果（R17 差异吸收——微信异步 / 支付宝同步统一为
    受理 :ok，最终态经回调/查单收敛）。
  - 回调验签：RSA2（Alipay.Crypto.verify_callback），表单参数集验签。
  - 对账单：fetch_bill_download_url → 下载 zip/csv → 行 map 化。

  密钥缺失时返回 {:error, :provider_not_configured}（同 WechatPay 语义）。
  支付宝沙箱联调视账号可得性（Deferred），真实小额验收上线前人工。
  """

  @behaviour Cgc2046.Payments.Provider

  alias Alipay.Trade

  @config_key :alipay_pay

  # 手写 runtime client（宏版本编译期固化密钥，见 moduledoc）
  defmodule Client do
    @moduledoc false

    def post(url, body, opts \\ []), do: Alipay.Requester.post(__MODULE__, url, body, opts)
    def get(url, opts \\ []), do: Alipay.Requester.get(__MODULE__, url, opts)

    def app_id, do: config()[:app_id]

    # 应用私钥（PEM 或裸 base64 PKCS#8，Alipay.Middleware.Authorization 消费）
    def private_key do
      decode_pem(config()[:private_key])
    end

    def callback_public_key do
      decode_pem(config()[:public_key])
    end

    def sandbox?, do: !!config()[:sandbox]

    defp config, do: Application.get_env(:cgc_2046, :alipay_pay, [])

    defp decode_pem(nil), do: nil

    # 裸 base64 自适应：PKCS#1/PKCS#8 私钥或 SPKI 公钥——分别包对应 PEM 头，
    # 交给 :public_key.pem_decode 按标准 ASN.1 处理（避免手写 DER 解析）。
    defp decode_pem(pem) when is_binary(pem) do
      cond do
        String.contains?(pem, "BEGIN") ->
          :public_key.pem_decode(pem) |> List.first() |> :public_key.pem_entry_decode()

        true ->
          b64 = pem |> String.split(~r/\s+/) |> Enum.join()
          # 公钥(SPKI)优先:私钥 bytes 误包 PUBLIC KEY 头会解出错模数(实测踩坑),
          # 且本 adapter 公私钥来源固定(公钥=SPKI,私钥=PKCS#1/8),按钥型分派最稳
          labels =
            if byte_size(b64) < 500,
              do: ["PUBLIC KEY", "RSA PRIVATE KEY", "PRIVATE KEY"],
              else: ["RSA PRIVATE KEY", "PRIVATE KEY", "PUBLIC KEY"]

          decode_b64_as_pem(b64, labels)
      end
    end

    defp decode_b64_as_pem(b64, [label | rest]) do
      wrapped = "-----BEGIN #{label}-----\n#{b64}\n-----END #{label}-----\n"

      case :public_key.pem_decode(wrapped) do
        [entry] ->
          try do
            :public_key.pem_entry_decode(entry)
          rescue
            _ -> decode_b64_as_pem(b64, rest)
          end

        _ ->
          decode_b64_as_pem(b64, rest)
      end
    end

    defp decode_b64_as_pem(_b64, []), do: raise(ArgumentError, message: "unrecognized key format")
  end

  @impl Cgc2046.Payments.Provider
  def create_payment(order, _ctx) do
    with {:ok, _} <- ensure_configured() do
      endpoint = payment_endpoint(order.provider)

      body =
        %{out_trade_no: order.out_trade_no, total_amount: yuan(order.amount_cents)}
        |> Map.put(:subject, payment_subject(order))
        |> Map.put(:notify_url, notify_url())
        |> maybe_put_return_url(order.provider)

      case Client.post(endpoint, body) do
        {:ok, %Tesla.Env{status: 200, body: resp}} ->
          credential(order.provider, resp)

        {:ok, %Tesla.Env{}} ->
          {:error, :channel_create_failed}

        {:error, _} = error ->
          error
      end
    end
  end

  # 当面付二维码（已签约产品）：qr_code 链接即凭据；page/wap 跳转型。
  defp credential(:alipay_qr, %{"qr_code" => qr}) when is_binary(qr),
    do: {:ok, %{"type" => "qr_code", "code_url" => qr}}

  defp credential(_provider, resp) do
    case payment_url(resp) do
      nil -> {:error, :channel_payment_url_missing}
      url -> {:ok, %{"type" => "redirect", "url" => url}}
    end
  end

  defp maybe_put_return_url(body, provider) do
    # precreate 无 return_url 概念（扫码即付，无浏览器回跳）
    if provider == :alipay_qr, do: body, else: Map.put(body, :return_url, config()[:return_url])
  end

  @impl Cgc2046.Payments.Provider
  def fetch_transaction(out_trade_no) do
    with {:ok, _} <- ensure_configured() do
      case Trade.query(Client, %{out_trade_no: out_trade_no}) do
        {:ok, %Tesla.Env{status: 200, body: %{"trade_status" => status} = body}} ->
          {:ok,
           %{
             status: normalize_state(status),
             amount_cents: cents(body["total_amount"]),
             transaction_id: body["trade_no"] || ""
           }}

        {:ok, %Tesla.Env{status: 404}} ->
          {:error, :order_not_found}

        {:ok, %Tesla.Env{}} ->
          {:error, :channel_query_failed}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def refund(order) do
    with {:ok, _} <- ensure_configured() do
      body = %{
        out_trade_no: order.out_trade_no,
        refund_amount: yuan(order.amount_cents),
        out_request_no: "rf-" <> order.out_trade_no
      }

      case Trade.refund(Client, body) do
        # 同步接口（KTD17）：200 受理即资金处理完成。refund_status 终态信号
        # 在响应内消费（成功值收敛 completed；其余非空值按拒绝上报——宁拒勿假，
        # 误报可经 retry_refund 重入，假成功则静默卡死）。
        {:ok, %Tesla.Env{status: 200, body: %{"refund_status" => "REFUND_SUCCESS"}}} ->
          {:ok, :completed}

        {:ok, %Tesla.Env{status: 200, body: %{"refund_status" => _other}}} ->
          {:error, :channel_refund_failed}

        # v3 退款 200 且无 refund_status 字段即成功（同步语义，无失败信号）
        {:ok, %Tesla.Env{status: 200}} ->
          {:ok, :completed}

        {:ok, %Tesla.Env{}} ->
          {:error, :channel_refund_failed}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def verify_webhook(raw_body, _headers) do
    with {:ok, public_key} <- callback_public_key() do
      params = url_decode_form(raw_body)

      sign = params["sign"]

      if is_binary(sign) and sign != "" and Alipay.Crypto.verify_callback(params, public_key) do
        {:ok, params}
      else
        :error
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_statement(date) do
    with {:ok, _} <- ensure_configured() do
      case Trade.fetch_bill_download_url(Client, %{
             bill_type: "trade",
             bill_date: Calendar.strftime(date, "%Y-%m-%d")
           }) do
        {:ok, %Tesla.Env{status: 200, body: %{"bill_download_url" => url}}} ->
          case Client.get(url) do
            {:ok, %Tesla.Env{status: 200, body: csv}} when is_binary(csv) ->
              {:ok, parse_statement_csv(csv)}

            _ ->
              {:error, :bill_fetch_failed}
          end

        {:ok, %Tesla.Env{}} ->
          {:error, :bill_not_ready}

        {:error, _} = error ->
          error
      end
    end
  end

  # ── 配置 ───────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:cgc_2046, @config_key, [])

  defp ensure_configured do
    if config()[:app_id] && config()[:private_key] do
      {:ok, :configured}
    else
      {:error, :provider_not_configured}
    end
  end

  defp callback_public_key do
    case Client.callback_public_key() do
      nil -> {:error, :provider_not_configured}
      key -> {:ok, key}
    end
  end

  defp notify_url do
    config()[:webhook_base_url] |> Path.join("/api/payments/webhooks/alipay")
  end

  # 支付宝 v3 网页支付端点：电脑网站 / 手机网站（跳转 URL 由响应给出；
  # 字段名以真实联调为准，adapter 隔离该差异——KTD3）
  defp payment_endpoint(:alipay_page), do: "/v3/alipay/trade/page/pay"
  defp payment_endpoint(:alipay_wap), do: "/v3/alipay/trade/wap/pay"
  # 当面付（本应用唯一已签约产品，真实验收实证 2026-08-17）
  defp payment_endpoint(:alipay_qr), do: "/v3/alipay/trade/precreate"

  defp payment_url(resp) when is_map(resp) do
    resp["payment_url"] || resp["payUrl"] || resp["qrCode"] || resp["redirect_url"]
  end

  defp payment_url(_), do: nil

  defp payment_subject(order) do
    case order.tier_snapshot do
      %{"name" => name} when is_binary(name) -> name
      _ -> "CGC 报名缴费"
    end
  end

  # 金额一律分（R20）；支付宝侧元字符串（两位小数）
  defp yuan(amount_cents), do: :erlang.float_to_binary(amount_cents / 100, decimals: 2)

  defp cents(nil), do: 0

  defp cents(amount) when is_binary(amount) do
    case Float.parse(amount) do
      {yuan_value, _} -> round(yuan_value * 100)
      :error -> 0
    end
  end

  defp normalize_state("TRADE_SUCCESS"), do: :paid
  defp normalize_state("TRADE_FINISHED"), do: :paid
  defp normalize_state("WAIT_BUYER_PAY"), do: :pending
  defp normalize_state("TRADE_CLOSED"), do: :closed
  defp normalize_state(_), do: :pending

  # 支付宝异步通知为 application/x-www-form-urlencoded
  defp url_decode_form(raw_body) do
    URI.query_decoder(raw_body)
    |> Enum.map(fn {k, v} -> {k, v} end)
    |> Map.new()
  end

  @doc """
  支付宝账单 CSV/明细 → 行 map 列表（规⑦ 差异比对行形状）。

  公开面：U13 对账 worker 与样例文件测试共用（样例文件驱动，语义同
  WechatPay.parse_statement_csv/1）。
  """
  def parse_statement_csv(csv) do
    lines = String.split(csv, "\n", trim: true)

    case Enum.reject(lines, &String.starts_with?(&1, "#")) do
      [] ->
        []

      [header | rows] ->
        keys = String.split(String.trim_trailing(header, "\r"), ",")

        Enum.map(rows, fn row ->
          keys
          |> Enum.zip(String.split(String.trim_trailing(row, "\r"), ","))
          |> Map.new()
        end)
    end
  end
end
