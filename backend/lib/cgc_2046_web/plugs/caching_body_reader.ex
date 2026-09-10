defmodule Cgc2046Web.Plugs.CachingBodyReader do
  @moduledoc """
  raw body 缓存 body_reader（缴费闭环 U6，KTD4）。

  挂在 endpoint 全局 `Plug.Parsers` 上（选全局而非路由级：endpoint 层 Parsers
  先于 router 解析，路由级方案需绕过全局 Parsers，复杂度更高；代价 = 每请求
  一份 body 内存，可接受）。解析行为零变化——只把原始 body 顺手存进
  `conn.private[:raw_body]`，渠道回调验签需要逐字节原文（微信 APIv3 签名覆盖
  原始 body，任何重序列化都会破坏验签）。

  017 审计修复 + 复审 F1：`{:more, chunk, conn}` 分块逐段累积后再落
  `raw_body`——此前只存最后一次 `:ok` 读到的块，超过单次读取上限的回调体
  会静默丢失前置分块、验签必败。**总量上限保持不变**：累积超过 Parsers 的
  `:length`（默认 8MB）即返回 `{:more, <<>>, conn}`，由 Parsers 按既有契约
  抛 too_large → 413——这是本 reader 的唯一总量闸门，不可移除（公开端点
  无认证可直达）。
  """

  @default_max_length 8_000_000

  @doc false
  def read_body(conn, opts), do: do_read(conn, opts, [])

  defp do_read(conn, opts, acc) do
    max_length = Keyword.get(opts, :length, @default_max_length)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw = IO.iodata_to_binary([acc, body])
        {:ok, raw, Plug.Conn.put_private(conn, :raw_body, raw)}

      {:more, body, conn} ->
        acc = [acc, body]

        if IO.iodata_length(acc) > max_length do
          # 超过总量上限：交还 {:more} 让 Parsers 走既有 too_large → 413 路径，
          # 累积缓冲就地丢弃。绝不能吞掉后续分块读到 EOF——那会移除公开
          # 端点唯一的请求体总量闸门（复审 F1）。
          {:more, <<>>, conn}
        else
          do_read(conn, opts, acc)
        end

      {:error, _} = error ->
        error
    end
  end
end
