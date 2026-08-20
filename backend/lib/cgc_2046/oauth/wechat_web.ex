defmodule Cgc2046.OAuth.WechatWeb do
  @moduledoc """
  微信开放平台网站应用扫码登录 HTTP 层（plan 002 U4，D1：Req 直调不走 SDK）。

  三个端点全部 Req 直调（小程序 code2session 同款先例——OfficialAccount
  client 会自动注入 access_token / 启动 refresher，网站应用无 client_credential
  能力，行为不确定）：

  - `qr_connect_url/2`：手拼 `https://open.weixin.qq.com/connect/qrconnect`
  - `code2access_token/1`：`/sns/oauth2/access_token`
  - `user_info/2`：`/sns/userinfo`（nickname 用于 display_name，可选）

  配置：`config :cgc_2046, :wechat_web, [appid:, secret:]`（可缺——门禁
  `wechat_login_unavailable`）。测试 seam：`config :cgc_2046, :wechat_web_req_plug`。
  """

  @qr_base "https://open.weixin.qq.com/connect/qrconnect"
  @sns_base "https://api.weixin.qq.com/sns"

  @doc false
  @spec configured? :: boolean()
  def configured? do
    config = Application.get_env(:cgc_2046, :wechat_web, [])
    appid = blank_to_nil(config[:appid])
    secret = blank_to_nil(config[:secret])
    appid != nil and secret != nil
  end

  @doc """
  qrconnect 扫码页 URL（iframe 嵌入；微信在用户确认后重定向顶层窗口到
  `redirect_uri?code=&state=`）。
  """
  @spec qr_connect_url(String.t(), String.t()) ::
          String.t() | {:error, :wechat_web_not_configured}
  def qr_connect_url(redirect_uri, state) do
    if configured?() do
      appid = Application.fetch_env!(:cgc_2046, :wechat_web)[:appid]

      params = [
        {"appid", appid},
        {"redirect_uri", redirect_uri},
        {"response_type", "code"},
        {"scope", "snsapi_login"},
        {"state", state}
      ]

      query = URI.encode_query(params)
      "#{@qr_base}?#{query}#wechat_redirect"
    else
      {:error, :wechat_web_not_configured}
    end
  end

  @doc """
  code 换 access_token（`/sns/oauth2/access_token`）。
  成功 `{:ok, %{openid, unionid, access_token}}`；unionid 可能缺失（开放平台
  未绑同一主体）→ nil。错误已净化（不含 secret）。
  """
  @spec code2access_token(String.t()) ::
          {:ok, %{openid: String.t(), unionid: String.t() | nil, access_token: String.t()}}
          | {:error, term()}
  def code2access_token(code) when is_binary(code) do
    if configured?() do
      config = Application.fetch_env!(:cgc_2046, :wechat_web)

      case Req.get(req(@sns_base),
             url: "/oauth2/access_token",
             params: [
               appid: config[:appid],
               secret: config[:secret],
               code: code,
               grant_type: "authorization_code"
             ]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"errcode" => errcode}} = resp}
        when is_integer(errcode) and errcode != 0 ->
          {:error, {:wechat_web_code_rejected, errcode, resp.body["errmsg"]}}

        {:ok,
         %Req.Response{status: 200, body: %{"access_token" => at, "openid" => openid} = body}} ->
          {:ok, %{openid: openid, unionid: blank_to_nil(body["unionid"]), access_token: at}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:wechat_web_bad_response, status, body}}

        {:error, reason} ->
          {:error, {:wechat_web_network, reason}}
      end
    else
      {:error, :wechat_web_not_configured}
    end
  end

  @doc """
  拉 `/sns/userinfo`（nickname 用于 display_name，可选路径——失败不阻断登录）。
  """
  @spec user_info(String.t(), String.t()) ::
          {:ok, %{nickname: String.t() | nil}} | {:error, term()}
  def user_info(openid, access_token) when is_binary(openid) and is_binary(access_token) do
    case Req.get(req(@sns_base),
           url: "/userinfo",
           params: [access_token: access_token, openid: openid]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"errcode" => 0} = body}} ->
        {:ok, %{nickname: body["nickname"]}}

      {:ok, %Req.Response{status: 200, body: %{"nickname" => nickname}}} ->
        {:ok, %{nickname: nickname}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:wechat_web_userinfo_failed, status, body}}

      {:error, reason} ->
        {:error, {:wechat_web_network, reason}}
    end
  end

  defp req(base) do
    opts = [base_url: base, receive_timeout: 5_000, retry: false, redirect: false]

    case Application.get_env(:cgc_2046, :wechat_web_req_plug) do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_), do: nil
end
