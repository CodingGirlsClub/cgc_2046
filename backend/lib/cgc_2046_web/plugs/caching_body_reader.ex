defmodule Cgc2046Web.Plugs.CachingBodyReader do
  @moduledoc """
  raw body 缓存 body_reader（缴费闭环 U6，KTD4）。

  挂在 endpoint 全局 `Plug.Parsers` 上（选全局而非路由级：endpoint 层 Parsers
  先于 router 解析，路由级方案需绕过全局 Parsers，复杂度更高；代价 = 每请求
  一份 body 内存，可接受）。解析行为零变化——只把原始 body 顺手存进
  `conn.private[:raw_body]`，渠道回调验签需要逐字节原文（微信 APIv3 签名覆盖
  原始 body，任何重序列化都会破坏验签）。
  """

  @doc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}

      {:more, body, conn} ->
        {:more, body, conn}

      {:error, _} = error ->
        error
    end
  end
end
