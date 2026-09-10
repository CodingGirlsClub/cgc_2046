defmodule Cgc2046Web.Plugs.CachingBodyReader do
  @moduledoc """
  raw body 缓存 body_reader（缴费闭环 U6，KTD4）。

  挂在 endpoint 全局 `Plug.Parsers` 上（选全局而非路由级：endpoint 层 Parsers
  先于 router 解析，路由级方案需绕过全局 Parsers，复杂度更高；代价 = 每请求
  一份 body 内存，可接受）。解析行为零变化——只把原始 body 顺手存进
  `conn.private[:raw_body]`，渠道回调验签需要逐字节原文（微信 APIv3 签名覆盖
  原始 body，任何重序列化都会破坏验签）。

  017 审计修复：`{:more, chunk, conn}` 分块逐段累积后再落 `raw_body`——此前
  只存最后一次 `:ok` 读到的块，超过单次读取上限的回调体会静默丢失前置分块、
  验签必败（fail-closed 的可用性悬崖）。内存上限由 Parsers 的既有 length
  选项兜底，不新增配置。
  """

  @doc false
  def read_body(conn, opts), do: do_read(conn, opts, [])

  defp do_read(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw = IO.iodata_to_binary([acc, body])
        {:ok, raw, Plug.Conn.put_private(conn, :raw_body, raw)}

      {:more, body, conn} ->
        do_read(conn, opts, [acc, body])

      {:error, _} = error ->
        error
    end
  end
end
