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

  alias AshAuthentication.Phoenix.Oauth2Server.Errors

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
    key = Cgc2046Web.Plugs.RateLimit.key_for(@quota_key_prefix, conn)

    if Cgc2046Web.Plugs.RateLimit.check(
         key,
         max_attempts: max_attempts(),
         window_seconds: window_seconds()
       ) == :ok do
      conn
    else
      # 429 信封交给库协议端点同款 helper（content-type/cache-control/正文形状
      # 与其一致；retry-after 须先设，send_resp 由 helper 完成并 halt）。
      conn
      |> put_resp_header("retry-after", Integer.to_string(window_seconds()))
      |> Errors.send_oauth_error(
        429,
        "rate_limited",
        "client registration quota exceeded; retry later"
      )
    end
  end

  defp max_attempts, do: config() |> Keyword.get(:max_attempts, @default_max_attempts)

  defp window_seconds, do: config() |> Keyword.get(:window_seconds, @default_window_seconds)

  defp config, do: Application.get_env(:cgc_2046, __MODULE__, [])
end
