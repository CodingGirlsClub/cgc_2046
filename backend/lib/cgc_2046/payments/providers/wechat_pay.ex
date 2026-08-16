defmodule Cgc2046.Payments.Providers.WechatPay do
  @moduledoc """
  微信支付 APIv3 adapter（KTD3/KTD7，ADR-0007 平台统一商户号）。

  微信沙箱不可靠（#172 拍板：以 mock 为主），本 adapter 的渠道调用只在
  dev/prod 真实密钥下执行；测试一律走 Fake。真实小额验收在上线前人工完成。

  - client 经 `WeChat.Pay.build_client/2` 运行时构建（密钥从应用环境读取，
    `:persistent_term` 按配置指纹缓存，配置变更自动重建）。
  - 凭据形状：JSAPI → `request_payment_args` 调起参数；Native → `code_url`。
  - 回调验签：Wechatpay-Signature/Timestamp/Nonce/Serial 头 + 平台证书公钥
    RSA-SHA256，资源体 AEAD_AES_256_GCM 解密（SDK Crypto 模块）。
  - 退款异步：受理成功即 :ok，结果经退款回调/查单收敛（R17 在 adapter 内吸收）。

  密钥缺失时全部入口返回 {:error, :provider_not_configured}——不静默外呼，
  boot 不因缺密钥崩溃（真实验收前可安全部署）。
  """

  @behaviour Cgc2046.Payments.Provider

  alias WeChat.Pay.{Bill, Certificates, Crypto, Refund, Transactions}

  @config_key :wechat_pay

  @impl Cgc2046.Payments.Provider
  def create_payment(order, ctx) do
    with {:ok, client} <- fetch_client() do
      config = config()
      description = payment_description(order)

      body = %{
        appid: config[:appid],
        mchid: config[:mch_id],
        description: description,
        out_trade_no: order.out_trade_no,
        notify_url: notify_url(),
        amount: %{total: order.amount_cents, currency: "CNY"}
      }

      case order.provider do
        :wechat_jsapi ->
          with {:ok, openid} <- fetch_openid(ctx),
               {:ok, %Tesla.Env{status: 200, body: %{"prepay_id" => prepay_id}}} <-
                 post(Transactions.jsapi(client, Map.put(body, :payer, %{openid: openid}))) do
            {:ok,
             %{
               "type" => "jsapi",
               "pay_params" =>
                 stringify_keys(
                   Transactions.request_payment_args(client, config[:appid], prepay_id)
                 )
             }}
          end

        :wechat_native ->
          with {:ok, %Tesla.Env{status: 200, body: %{"code_url" => code_url}}} <-
                 post(Transactions.native(client, body)) do
            {:ok, %{"type" => "qr_code", "code_url" => code_url}}
          end
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_transaction(out_trade_no) do
    with {:ok, client} <- fetch_client() do
      with {:ok,
            %Tesla.Env{
              status: 200,
              body: %{"trade_state" => state, "amount" => %{"total" => total}} = body
            }} <- post(Transactions.query_by_out_trade_no(client, out_trade_no)) do
        {:ok,
         %{
           status: normalize_state(state),
           amount_cents: total,
           transaction_id: body["transaction_id"] || ""
         }}
      else
        {:ok, %Tesla.Env{status: 404}} -> {:error, :order_not_found}
        {:ok, %Tesla.Env{}} -> {:error, :channel_query_failed}
        {:error, _} = error -> error
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def refund(order) do
    with {:ok, client} <- fetch_client() do
      with {:ok, %Tesla.Env{status: 200}} <-
             post(
               Refund.refund_by_out_trade_no(
                 client,
                 order.out_trade_no,
                 "rf-" <> order.out_trade_no,
                 order.amount_cents,
                 order.amount_cents,
                 notify_url()
               )
             ) do
        :ok
      else
        {:ok, %Tesla.Env{}} -> {:error, :channel_refund_failed}
        {:error, _} = error -> error
      end
    end
  end

  @impl Cgc2046.Payments.Provider
  def verify_webhook(raw_body, headers) do
    with {:ok, client} <- fetch_client(),
         signature when is_binary(signature) <- header(headers, "wechatpay-signature"),
         timestamp when is_binary(timestamp) <- header(headers, "wechatpay-timestamp"),
         nonce when is_binary(nonce) <- header(headers, "wechatpay-nonce"),
         serial when is_binary(serial) <- header(headers, "wechatpay-serial"),
         public_key when not is_nil(public_key) <- Certificates.get_cert(client, serial),
         true <- Crypto.verify(signature, timestamp, nonce, raw_body, public_key),
         {:ok, body_map} <- Jason.decode(raw_body) do
      decrypt_resource(client, body_map)
    else
      _ -> :error
    end
  end

  @impl Cgc2046.Payments.Provider
  def fetch_statement(date) do
    with {:ok, client} <- fetch_client() do
      with {:ok, %Tesla.Env{status: 200, body: %{"download_url" => url}}} <-
             post(Bill.trade_bill(client, Calendar.strftime(date, "%Y-%m-%d"))),
           {:ok, %Tesla.Env{status: 200, body: csv}} <- post(Bill.download_bill(client, url)) do
        {:ok, parse_csv(csv)}
      else
        {:ok, %Tesla.Env{status: 400}} -> {:error, :bill_not_ready}
        {:ok, %Tesla.Env{}} -> {:error, :bill_fetch_failed}
        {:error, _} = error -> error
      end
    end
  end

  # ── client 构建与配置 ──────────────────────────────────────────────────────

  defp config, do: Application.get_env(:cgc_2046, @config_key, [])

  defp configured? do
    config()[:mch_id] && config()[:appid] && config()[:api_v3_key] &&
      config()[:client_serial_no] && config()[:client_private_key]
  end

  # 运行时 client：WeChat.Pay 宏在编译期固化密钥（与 KTD7 runtime 注入冲突），
  # SDK 官方动态入口 build_client/2 + persistent_term 缓存（配置指纹变更重建）。
  defp fetch_client do
    if configured?() do
      {:ok, build_cached_client()}
    else
      {:error, :provider_not_configured}
    end
  end

  defp build_cached_client do
    fingerprint = :erlang.phash2(config())

    case :persistent_term.get({__MODULE__, fingerprint}, nil) do
      nil ->
        client_module = Module.concat(__MODULE__, "Client#{fingerprint}")

        case WeChat.Pay.build_client(client_module,
               mch_id: config()[:mch_id],
               api_secret_key: config()[:api_v3_key],
               client_serial_no: config()[:client_serial_no],
               client_key: {:binary, config()[:client_private_key]}
             ) do
          {:ok, module} ->
            :persistent_term.put({__MODULE__, fingerprint}, module)
            module

          {:error, reason} ->
            raise "wechat pay client build failed: #{inspect(reason)}"
        end

      module ->
        module
    end
  end

  defp notify_url do
    config()[:webhook_base_url] |> Path.join("/api/payments/webhooks/wechat")
  end

  defp payment_description(order) do
    case order.tier_snapshot do
      %{"name" => name} when is_binary(name) -> name
      _ -> "CGC 报名缴费"
    end
  end

  defp fetch_openid(%{openid: openid}) when is_binary(openid) and openid != "", do: {:ok, openid}
  defp fetch_openid(_ctx), do: {:error, :openid_required}

  # ── 回调解密 ───────────────────────────────────────────────────────────────

  defp decrypt_resource(client, %{
         "resource_type" => "encrypt-resource",
         "resource" => %{
           "algorithm" => "AEAD_AES_256_GCM",
           "nonce" => iv,
           "ciphertext" => ciphertext,
           "associated_data" => associated_data
         }
       }) do
    decrypted =
      Crypto.decrypt_aes_256_gcm(client.api_secret_key(), ciphertext, associated_data, iv)

    case Jason.decode(decrypted) do
      {:ok, event} when is_map(event) -> {:ok, event}
      _ -> :error
    end
  end

  # 非加密资源体（如部分退款通知直接明文）原样返回
  defp decrypt_resource(_client, body_map) when is_map(body_map), do: {:ok, body_map}

  # ── 工具 ───────────────────────────────────────────────────────────────────

  defp post({:ok, %Tesla.Env{} = env}), do: {:ok, env}
  defp post({:error, _} = error), do: error
  defp post(response), do: {:ok, response}

  defp header(headers, key) do
    Map.get(headers, key) || Map.get(headers, String.capitalize(key, mode: :title))
  end

  defp normalize_state("SUCCESS"), do: :paid
  defp normalize_state("NOTPAY"), do: :pending
  defp normalize_state("USERPAYING"), do: :pending
  defp normalize_state("CLOSED"), do: :closed
  defp normalize_state("REVOKED"), do: :closed
  defp normalize_state("PAYERROR"), do: :closed
  defp normalize_state("REFUND"), do: :refunded
  defp normalize_state(_), do: :pending

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # 微信账单 CSV：首行表头，后续行按表头 zip 成 map（规⑦ 差异比对的行形状）
  defp parse_csv(csv) when is_binary(csv) do
    lines = String.split(csv, "\n", trim: true)
    # 汇总行（最后）以总计开头，非数据行
    data_lines = Enum.reject(lines, &String.starts_with?(&1, "总"))

    case data_lines do
      [] ->
        []

      [header | rows] ->
        keys = header |> String.split("`", trim: true) |> Enum.map(&String.trim_trailing(&1, "`"))

        Enum.map(rows, fn row ->
          keys
          |> Enum.zip(row |> String.split("`", trim: true))
          |> Map.new()
        end)
    end
  end

  defp parse_csv(_), do: []
end
