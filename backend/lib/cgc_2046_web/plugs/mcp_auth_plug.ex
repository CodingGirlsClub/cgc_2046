defmodule Cgc2046Web.Plugs.McpAuthPlug do
  @moduledoc """
  MCP endpoint Bearer 鉴权（D13 / plan P1.4）。

  `Authorization: Bearer <plain_token>` → `Cgc2046.Mcp.Token.validate_token/1`：
  - 有效：`assign(:current_user, user)`（anubis transport 会把 conn.assigns 透传进
    tool frame.assigns，见 `Cgc2046.Mcp.Wrapper`）
  - 无效/缺失：401 + `WWW-Authenticate`（RFC 6750）
  """
  @behaviour Plug

  import Plug.Conn

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
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="cgc-2046-mcp", error="invalid_token"))
    |> send_resp(401, ~s({"error":"invalid_token"}))
    |> halt()
  end
end
