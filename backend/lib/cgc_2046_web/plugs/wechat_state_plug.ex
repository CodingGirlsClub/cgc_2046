defmodule Cgc2046Web.Plugs.WechatStatePlug do
  @moduledoc """
  微信扫码登录的浏览器绑定 cookie（advisor02 M2）。

  `wechatLoginStart` 经 AuthCookiePlug.before_send 下发 httpOnly
  `cgc_wechat_state`（= ticket state，10min）；本 plug 在请求期读回并塞进
  Absinthe context `:wechat_browser_state`，供 signInWithWechat /
  bindWechatWithPhone 校验「state 由发起浏览器持有」——钓鱼链接无法在
  受害者浏览器完成登录/绑定（QR-login CSRF 防护）。

  挂在 :graphql pipeline 的 load_from_bearer 之后（与 AuthTokenContextPlug
  同位：AshGraphql.Plug 的 Map.merge 只覆盖 actor/tenant/context 三键）。
  """
  @behaviour Plug
  import Plug.Conn

  @context_key :wechat_browser_state

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.req_cookies["cgc_wechat_state"] do
      state when is_binary(state) and state != "" ->
        absinthe = Map.get(conn.private, :absinthe, %{})
        context = Map.put(Map.get(absinthe, :context, %{}), @context_key, state)
        put_private(conn, :absinthe, Map.put(absinthe, :context, context))

      _ ->
        conn
    end
  end
end
