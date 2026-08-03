defmodule Cgc2046Web.Plugs.AuthCookiePlug do
  @moduledoc """
  httpOnly 认证 cookie 的读/写/清。

  - `read/2`：把 `cgc_token` cookie 值合成进 Authorization 头，供既有 `load_from_bearer` 复用。
    cookie 是 httpOnly，JS 读不到；服务端内部转成 bearer 仅为本仓复用 AshAuthentication 的 bearer 验证路径。
  - `before_send/2`：Absinthe.Plug 内置钩子，解析后从 blueprint context 读 token 写 httpOnly cookie，
    或读清除信号 `delete_resp_cookie`。
  """
  import Plug.Conn

  @cookie_key "cgc_token"

  def cookie_key, do: @cookie_key

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: read(conn, [])

  @doc """
  读 cookie 并合成 Authorization 头。
  在 `:graphql` 管线 `load_from_bearer` 之前调用。
  """
  def read(conn, _opts) do
    case conn.req_cookies[@cookie_key] do
      nil -> conn
      token -> put_req_header(conn, "authorization", "Bearer " <> token)
    end
  end

  @doc """
  Absinthe.Plug `before_send` 回调。

  从 blueprint context 读取 token 或清除信号，写/清 httpOnly cookie。
  """
  def before_send(conn, %{execution: %{context: context}}) do
    cond do
      context[:cgc_clear_token] ->
        delete_resp_cookie(conn, @cookie_key)

      token = context[:cgc_auth_token] ->
        put_resp_cookie(conn, @cookie_key, token,
          http_only: true,
          secure: Application.get_env(:cgc_2046, :auth_cookie_secure, true),
          same_site: "Lax",
          max_age: 60 * 60 * 24
        )

      true ->
        conn
    end
  end

  def before_send(conn, _), do: conn
end
