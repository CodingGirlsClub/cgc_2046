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
    conn
    |> write_token_cookie(context)
    |> write_wechat_state_cookie(context)
  end

  def before_send(conn, _), do: conn

  defp write_token_cookie(conn, context) do
    cond do
      context[:cgc_clear_token] ->
        delete_resp_cookie(conn, @cookie_key)

      token = context[:cgc_auth_token] ->
        put_resp_cookie(conn, @cookie_key, token,
          http_only: true,
          secure: Application.get_env(:cgc_2046, :auth_cookie_secure, true),
          same_site: "Lax",
          # 与 AshAuthentication token_lifetime 对齐（Phase 1 起 7 天，见 user.ex tokens 块）。
          # cookie 比 token 早过期会导致用户登录次日即被判定未登录（token 仍有效但 cookie 已丢）。
          max_age: Application.get_env(:cgc_2046, :auth_cookie_max_age, 60 * 60 * 24 * 7)
        )

      true ->
        conn
    end
  end

  # advisor02 M2：wechatLoginStart 下发 state 绑定 cookie（10min 对齐 ticket TTL；
  # Lax + httpOnly——顶层导航回调和同源 fetch 可带，跨站攻击页的 fetch 带不上）
  defp write_wechat_state_cookie(conn, context) do
    case context[:cgc_wechat_state_set] do
      state when is_binary(state) ->
        put_resp_cookie(conn, "cgc_wechat_state", state,
          http_only: true,
          secure: Application.get_env(:cgc_2046, :auth_cookie_secure, true),
          same_site: "Lax",
          max_age: 600
        )

      _ ->
        conn
    end
  end
end
