defmodule Cgc2046.Integrations.Wechat.WebLoginLaunch do
  @moduledoc "Login launch artifacts, using the existing SDK token lifecycle without request logging or retries."
  alias Cgc2046.Integrations.Wechat.SdkClient
  @page "pages/web-login/index"

  def generate(mode, public_code) when mode in [:qr, :link] do
    with {:ok, client} <- SdkClient.fetch(),
         {:ok, response} <- request(mode, public_code, client.get_access_token()) do
      parse(mode, public_code, response)
    else
      _ -> {:error, :mini_web_login_unavailable}
    end
  end

  defp request(mode, code, token) do
    {path, body} =
      case mode do
        :qr ->
          {"getwxacodeunlimit",
           %{page: @page, scene: "wl_" <> code, check_path: true, env_version: "release"}}

        :link ->
          # 微信 generate_urllink：`path` 必须是不带 query 的已发布页面路径，
          # 动态参数走单独的 `query` 字段——拼在短链 URL 上不会被传给小程序
          # （小程序端拿不到 requestId，报「登录链接无效」）。
          {"generate_urllink",
           %{path: @page, query: "cq=wl_" <> code, expire_type: 1, expire_interval: 1}}
      end

    opts = [
      url: "https://api.weixin.qq.com/wxa/" <> path,
      params: [access_token: token],
      json: body,
      retry: false,
      receive_timeout: 8_000,
      connect_options: [timeout: 8_000]
    ]

    opts =
      case Application.get_env(:cgc_2046, :miniprogram_req_plug) do
        nil -> opts
        plug -> Keyword.put(opts, :plug, plug)
      end

    # Bound the whole network operation, not just each connect/receive phase.
    task = Task.async(fn -> Req.post(opts) end)

    case Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, response} -> response
      _ -> {:error, :mini_web_login_unavailable}
    end
  end

  defp parse(:qr, _, %Req.Response{
         status: 200,
         body: <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
       })
       when byte_size(png) <= 1_048_576,
       do: {:ok, %{qr_data_url: "data:image/png;base64," <> Base.encode64(png)}}

  defp parse(:qr, _, %Req.Response{status: 200, body: <<255, 216, 255, _::binary>> = jpeg})
       when byte_size(jpeg) <= 1_048_576,
       do: {:ok, %{qr_data_url: "data:image/jpeg;base64," <> Base.encode64(jpeg)}}

  defp parse(:link, _code, %Req.Response{status: 200, body: %{"url_link" => link}})
       when is_binary(link) do
    case URI.parse(link) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil, userinfo: nil}
      when host in ["wxaurl.cn", "wxmpurl.cn"] ->
        {:ok, %{launch_url: link}}

      _ ->
        {:error, :mini_web_login_unavailable}
    end
  end

  defp parse(_, _, _), do: {:error, :mini_web_login_unavailable}
end
