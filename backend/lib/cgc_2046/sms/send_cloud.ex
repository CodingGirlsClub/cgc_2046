defmodule Cgc2046.Sms.SendCloud do
  @moduledoc """
  SendCloud 短信发送（plan 002 U3）。

  直调 `POST https://api.sendcloud.net/smsapi/send`（模板短信）。不进 Swoosh——
  SMS 非邮件，与 `Cgc2046.SwooshAdapters.SendCloud`（`/apiv2/mail/send`）是
  两个端点两套协议；Req 复用既有依赖（先例：miniprogram/client.ex、
  swoosh_adapters/send_cloud.ex）。

  签名（官档 https://www.sendcloud.net/doc/sms/ §API 验证机制）：
  参数（除 signature / smsKey）按 key 字典序拼 `k=v&…`，前后包 SMS_KEY，
  SHA256 hex 小写。

  配置（`config :cgc_2046, :sms_sendcloud`）：

      [
        sms_user: System.get_env("SENDCLOUD_SMS_USER"),
        sms_key: System.get_env("SENDCLOUD_SMS_KEY"),
        template_id: System.get_env("SENDCLOUD_SMS_TEMPLATE_ID")
      ]

  dev/test 为 dummy/占位；test 经 `config :cgc_2046, :sms_req_plug` 注入
  `{Req.Test, stub}`（miniprogram_req_plug 同款 seam）。
  """

  @base_url "https://api.sendcloud.net"
  @endpoint "/smsapi/send"

  @doc """
  发送模板短信。`vars` 为模板变量（如 `%{"code" => "123456"}`，JSON 编码后上送）；
  `send_request_id` 供渠道侧幂等去重。

  返回 `:ok | {:error, term}`；错误不含 sms_key 等敏感值。
  """
  @spec send_template_sms(String.t(), String.t(), map(), String.t()) ::
          :ok | {:error, term()}
  def send_template_sms(phone, template_id, vars, send_request_id)
      when is_binary(phone) and is_binary(template_id) and is_map(vars) and
             is_binary(send_request_id) do
    config = config()

    with {:ok, sms_user, sms_key} <- fetch_credentials(config) do
      timestamp = DateTime.to_unix(DateTime.utc_now()) |> Integer.to_string()

      params = %{
        "smsUser" => sms_user,
        "templateId" => template_id,
        "phone" => phone,
        "vars" => Jason.encode!(vars),
        "timestamp" => timestamp,
        "sendRequestId" => send_request_id
      }

      payload = Map.put(params, "signature", signature(params, sms_key))

      case Req.post(req(), url: @endpoint, form: payload) do
        {:ok, %Req.Response{status: status, body: %{"result" => true}}}
        when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:send_cloud_sms, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # 测试 seam：当前配置是否就绪（prod 缺凭证时发码路径统一降级，不 boot 崩）。
  def configured? do
    match?({:ok, _, _}, fetch_credentials(config()))
  end

  defp config, do: Application.get_env(:cgc_2046, :sms_sendcloud, [])

  defp fetch_credentials(config) do
    sms_user = blank_to_nil(config[:sms_user])
    sms_key = blank_to_nil(config[:sms_key])

    cond do
      is_nil(sms_user) or is_nil(sms_key) -> {:error, :sms_not_configured}
      true -> {:ok, sms_user, sms_key}
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_), do: nil

  @doc false
  # 签名算法单点（官档 §API 验证机制）；公开给测试锁定官方示例向量。
  def signature(params, sms_key) do
    plain =
      params
      |> Enum.reject(fn {k, _v} -> k in ["signature", "smsKey"] end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

    :crypto.hash(:sha256, sms_key <> plain <> sms_key)
    |> Base.encode16(case: :lower)
  end

  defp req do
    opts = [base_url: @base_url, receive_timeout: 5_000, retry: false, redirect: false]

    case Application.get_env(:cgc_2046, :sms_req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end
end
