defmodule Cgc2046Web.Plugs.OAuthRegisterQuotaPlug do
  @moduledoc """
  OAuth 动态客户端注册（`POST /oauth/register`）的按 IP 配额（RFC 7591 §5：
  匿名写端点「MAY be rate-limited」）。

  与 401 失败节流（`Cgc2046Web.Plugs.McpAuthPlug`）**分开定义**：独立 key 前缀
  （`rate:oauth-register` vs `rate:mcp-auth:*`，单点定义见本模块与 MCP plug 的
  分桶表），独立预算与窗口（默认 10 次/小时，app env 可调）——注册被限流不影响
  既有凭证的失败判定，反之亦然（KTD8/Risk 分桶要求）。

  计数按**注册尝试**（成功注册必然计入；失败注册同样计入——超额 429 拦在库的
  DCR 逻辑之前，避免非 loopback 试探/刷行免费消耗端点）。
  """

  @behaviour Plug

  import Plug.Conn

  @register_path "/oauth/register"
  @quota_key_prefix "rate:oauth-register"
  @default_max_attempts 10
  @default_window_seconds 3_600

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.method == "POST" and conn.request_path == @register_path do
      enforce(conn)
    else
      conn
    end
  end

  defp enforce(conn) do
    key = Cgc2046Web.Plugs.RateLimit.build_key(@quota_key_prefix, ip_string(conn))

    if Cgc2046Web.Plugs.RateLimit.check(
         key,
         max_attempts: max_attempts(),
         window_seconds: window_seconds()
       ) == :ok do
      conn
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("retry-after", Integer.to_string(window_seconds()))
      |> send_resp(
        429,
        Jason.encode!(%{
          "error" => "rate_limited",
          "error_description" => "client registration quota exceeded; retry later"
        })
      )
      |> halt()
    end
  end

  defp ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp max_attempts, do: config() |> Keyword.get(:max_attempts, @default_max_attempts)

  defp window_seconds, do: config() |> Keyword.get(:window_seconds, @default_window_seconds)

  defp config, do: Application.get_env(:cgc_2046, __MODULE__, [])
end
