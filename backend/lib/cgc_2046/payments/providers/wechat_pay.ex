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
  require Logger

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
        {:ok, parse_statement_csv(csv)}
      else
        {:ok, %Tesla.Env{status: 400}} -> {:error, :bill_not_ready}
        {:ok, %Tesla.Env{}} -> {:error, :bill_fetch_failed}
        {:error, _} = error -> error
      end
    end
  end

  # ── client 构建与配置 ──────────────────────────────────────────────────────

  defp config, do: Application.get_env(:cgc_2046, @config_key, [])

  # 七键齐才可用。空串 = 未配置（runtime env 注入缺值常得 ""）——is_binary and
  # != "" 归一，避免空串穿透门禁后在 build_client/notify_url 深处崩溃。
  # api_secret_v2_key：SDK build_client 硬性必需键（缺它 check_api_key 直接 raise）；
  # webhook_base_url：B3——漏配回调域名曾致 notify_url 的 Path.join(nil) 500。
  defp configured? do
    config = config()

    [
      :mch_id,
      :appid,
      :api_v3_key,
      :client_serial_no,
      :client_private_key,
      :api_secret_v2_key,
      :webhook_base_url
    ]
    |> Enum.all?(&configured_key?(config, &1))
  end

  defp configured_key?(config, key) do
    value = config[key]
    is_binary(value) and value != ""
  end

  @doc false
  # 测试 seam：当前配置指纹对应的 client 模块（未配置时为 nil）。
  def current_client do
    if configured?(), do: build_cached_client(), else: nil
  end

  # 运行时 client：WeChat.Pay 宏在编译期固化密钥（与 KTD7 runtime 注入冲突），
  # SDK 官方动态入口 build_client/2 + persistent_term 缓存（配置指纹变更重建）。
  defp fetch_client do
    if configured?() do
      try do
        {:ok, build_cached_client()}
      rescue
        # SDK build_client 是宏展开（check_api_key 等编译期校验吃不到运行时
        # 「未配置」语义），半配置（如缺 api_secret_key）在此 raise——真实小额
        # 验收实证：wechat 全空配置下默认渠道下单即崩 something_went_wrong。
        # 与 alipay 同语义降级 provider_not_configured。
        _ -> {:error, :provider_not_configured}
      end
    else
      {:error, :provider_not_configured}
    end
  end

  defp build_cached_client do
    fingerprint = :erlang.phash2(config())

    case cached_client(fingerprint) do
      nil ->
        shutdown_stale_client(fingerprint)
        client_module = Module.concat(__MODULE__, "Client#{fingerprint}")

        case WeChat.Pay.build_client(client_module,
               mch_id: config()[:mch_id],
               api_secret_key: config()[:api_v3_key],
               api_secret_v2_key: config()[:api_secret_v2_key],
               client_serial_no: config()[:client_serial_no],
               client_key: {:binary, config()[:client_private_key]}
             ) do
          {:ok, module} ->
            :ok = start_client_supervisor(module)
            :persistent_term.put({__MODULE__, fingerprint}, module)
            :persistent_term.put({__MODULE__, :current_fingerprint}, fingerprint)
            module

          {:error, reason} ->
            raise "wechat pay client build failed: #{inspect(reason)}"
        end

      module ->
        module
    end
  end

  # 缓存命中校验（advisor07 F1）：persistent_term 里的模块可能悬挂——ClientSup
  # 重启/发布重载会清空动态 child，但 persistent_term 保留旧模块名；命中分支
  # 直接返回则支付断流且零日志（Refresher/Finch 池已死，证书 nil、外呼 noproc）。
  # 挂起名 "#{module}.Supervisor" 存活才信任缓存；死亡即视为 miss 走重建
  # （Process.whereis 语义：:restarting 态返回 pid 但启动未完成——交给
  # start_client_supervisor 的 already_started 幂等分支兜住）。
  defp cached_client(fingerprint) do
    case :persistent_term.get({__MODULE__, fingerprint}, nil) do
      nil ->
        nil

      module ->
        if Process.whereis(:"#{module}.Supervisor"), do: module, else: nil
    end
  end

  defp notify_url do
    config()[:webhook_base_url] |> Path.join("/api/payments/webhooks/wechat")
  end

  # SDK 标准启动路径：use WeChat.Pay 的模块即 Supervisor，start_link 拉起
  # Refresher.Pay（平台证书加载/12h 轮换进 :persistent_term——不启动则
  # get_cert 恒 nil、验签恒 :error）与 per-client 命名 Finch 池
  # （："#{client_module}.Finch"，Requester.Pay 外呼依赖；不启动则首次外呼
  # noproc）。幂等：重复 start_child 对已运行同名 Supervisor 返回
  # {:error, {:already_started, _pid}} → 视为成功；其余错误向上抛
  # （fetch_client rescue → provider_not_configured）。
  defp start_client_supervisor(module) do
    case DynamicSupervisor.start_child(Cgc2046.Payments.ClientSup, {module, []}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        # advisor07 F2：启动失败不再静默——记录 module 与 reason 形状（不含密钥
        # 材料），错误语义保持既有降级（raise → fetch_client rescue →
        # provider_not_configured）。
        Logger.error(
          "WechatPay client supervisor start failed, module: #{inspect(module)}, reason: #{inspect(reason)}"
        )

        raise "wechat pay client start failed: #{inspect(reason)}"
    end
  end

  # 指纹变更（配置热更）：旧 client 的 Refresher/Finch 池先摘再建，防池泄漏
  # （persistent_term 无遍历，put 时顺记 :current_fingerprint 作索引）。
  # 注：WeChat.Pay.shutdown_client 按 child id 摘（普通 Supervisor 语义），对
  # DynamicSupervisor 不适用（其 child id 恒 :undefined）——按模块名匹配
  # which_children 后用原生 terminate_child/delete_child。
  defp shutdown_stale_client(fingerprint) do
    case :persistent_term.get({__MODULE__, :current_fingerprint}, nil) do
      old when old != fingerprint ->
        if module = :persistent_term.get({__MODULE__, old}, nil) do
          terminate_client_child(module)
          :persistent_term.erase({__MODULE__, old})
        end

        :ok

      _ ->
        :ok
    end
  end

  defp terminate_client_child(module) do
    Cgc2046.Payments.ClientSup
    |> DynamicSupervisor.which_children()
    |> Enum.filter(fn {_id, _pid, _type, mods} -> mods == [module] end)
    |> Enum.each(fn {_id, pid, _type, _mods} ->
      # DynamicSupervisor 无 delete_child——terminate 即自动摘除
      DynamicSupervisor.terminate_child(Cgc2046.Payments.ClientSup, pid)
    end)
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

  @doc """
  微信账单 CSV → 行 map 列表（规⑦ 差异比对行形状）。

  公开面：U13 对账 worker 与样例文件测试共用（无账单权限环境以
  test/fixtures/statement_samples 驱动，fetch_statement 不必真调渠道）。
  """
  def parse_statement_csv(csv) when is_binary(csv) do
    lines = String.split(csv, "\n", trim: true)
    # 汇总两行非数据行：文本行以「总」开头，数值行按表头字段数过滤
    data_lines = Enum.reject(lines, &String.starts_with?(&1, "总"))

    case data_lines do
      [] ->
        []

      [header | rows] ->
        # 分隔符 = 反引号+冒号；空值 = 反引号包裹的空串（官方格式）。段内
        # trim 反引号，空段保留（zip 长度对齐）。
        keys = split_backtick_row(header)
        width = length(keys)

        rows
        |> Enum.map(&split_backtick_row/1)
        |> Enum.filter(&(length(&1) == width))
        |> Enum.map(fn segs ->
          keys
          |> Enum.zip(segs)
          |> Map.new()
        end)
    end
  end

  def parse_statement_csv(_), do: []

  defp split_backtick_row(line) do
    line
    |> String.trim("\r")
    |> String.split("`:")
    |> Enum.map(&String.trim(&1, "`"))
  end
end
