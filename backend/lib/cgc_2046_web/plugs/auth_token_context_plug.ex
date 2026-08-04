defmodule Cgc2046Web.Plugs.AuthTokenContextPlug do
  @moduledoc """
  把 Authorization: Bearer <token> 的 token 字符串透传进 Absinthe context。

  AshAuthentication 的 `load_from_bearer` 验证完 token 后只把 user 放进
  `conn.assigns[:current_user]`，不保留原始 token 字符串——这是框架的安全
  设计（避免 token 泄漏到 resolvers/logs）。但 signOut middleware 需要原始
  token 才能调 `TokenResource.Actions.revoke/3` 做服务端撤销，而 Absinthe
  middleware 拿不到 Plug.Conn，所以这里把 token 塞进 `conn.private[:absinthe]
  [:context]`，供 signOut middleware 读取。

  放在 `:graphql` pipeline 的 `load_from_bearer` 之后、`AshGraphql.Plug` 之前：
  AshGraphql.Plug 的 `Map.merge(%{actor:, tenant:, context:})` 只覆盖这三个
  key，保留我们塞的 `cgc_bearer_token`。
  """
  @behaviour Plug
  import Plug.Conn

  @context_key :cgc_bearer_token

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [<<"Bearer ", token::binary>>] when byte_size(token) > 0 ->
        absinthe = Map.get(conn.private, :absinthe, %{})
        context = Map.put(Map.get(absinthe, :context, %{}), @context_key, token)
        put_private(conn, :absinthe, Map.put(absinthe, :context, context))

      _ ->
        conn
    end
  end
end
