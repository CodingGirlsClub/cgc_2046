defmodule Cgc2046Web.Plugs.McpAuthPlug do
  @moduledoc """
  MCP endpoint Bearer 鉴权（D13 / plan P1.4）。

  `Authorization: Bearer <plain_token>` → `Cgc2046.Mcp.Token.validate_token/1`：
  - 有效：`assign(:current_user, user)`（anubis transport 会把 conn.assigns 透传进
    tool frame.assigns，见 `Cgc2046.Mcp.Wrapper`）
  - 无效/缺失：401 + `WWW-Authenticate`（RFC 6750）

  ## 失败认证节流（#214）

  按 remote_ip 计**失败**认证次数（ETS 固定窗口，复用
  `Cgc2046Web.Plugs.RateLimit`；默认 20 次/15 分钟，app env
  `config :cgc_2046, Cgc2046Web.Plugs.McpAuthPlug, max_attempts:` 可调），
  超限后改 429 + `Retry-After`——防连接 token 暴力试探。有效 token 的
  成功认证不计数也不受节流影响（NAT 后的正常用户不被旁人拖累）。
  """
  @behaviour Plug

  import Plug.Conn

  @throttle_window_seconds 900

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         ["Bearer", token] <- String.split(header, " ", parts: 2),
         {:ok, user} <- Cgc2046.Mcp.Token.validate_token(token) do
      assign(conn, :current_user, user)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    key =
      Cgc2046Web.Plugs.RateLimit.build_key("rate:mcp-auth", ip_string(conn))

    if Cgc2046Web.Plugs.RateLimit.check(
         key,
         max_attempts: max_attempts(),
         window_seconds: @throttle_window_seconds
       ) == :ok do
      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer realm="cgc-2046-mcp", error="invalid_token")
      )
      |> send_resp(401, ~s({"error":"invalid_token"}))
      |> halt()
    else
      conn
      |> put_resp_header("retry-after", Integer.to_string(@throttle_window_seconds))
      |> send_resp(429, ~s({"error":"rate_limited"}))
      |> halt()
    end
  end

  defp ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp max_attempts,
    do:
      Application.get_env(:cgc_2046, __MODULE__, [])
      |> Keyword.get(:max_attempts, 20)
end
