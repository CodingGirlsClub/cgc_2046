defmodule Cgc2046Web.Plugs.CachingBodyReaderTest do
  @moduledoc """
  017：raw body 缓存 reader 的分块累积与总量上限守卫。

  测试适配器按 `:length` 逐次分块（每次调用返回至多 :length 字节）：

  - 分块累积路径：body > :length → 首调 `{:more}`、次调 `{:ok}` 剩余 →
    raw_body 必须是逐字节原文（旧实现只存最后一个块，此处失败）；
  - 总量上限路径：累积超过 `:length` → 返回 `{:more, <<>>, conn}` 交还
    Parsers 走 too_large → 413（复审 F1：公开端点唯一的总量闸门）。
  """

  use ExUnit.Case, async: true

  import Plug.Test

  @reader Cgc2046Web.Plugs.CachingBodyReader

  test "单块读取（body < :length）：raw_body == 完整原文" do
    body = ~s({"event_type":"TRANSACTION.SUCCESS","amount":100})

    conn = conn(:post, "/webhook/wechat", body)

    assert {:ok, ^body, conn} = @reader.read_body(conn, [])
    assert conn.private[:raw_body] == body
  end

  test "分块累积：首调 {:more} 次调 {:ok}，raw_body == 逐字节原文" do
    first = String.duplicate("x", 1_000)
    second = ~s({"out_trade_no":"oto-multi-chunk"})
    body = first <> second

    conn = conn(:post, "/webhook/wechat", body)

    # 旧实现此行返回 {:more, first, conn}（只回传首块且丢失累积）——测试失败
    assert {:ok, ^body, conn} = @reader.read_body(conn, length: 1_000)
    assert conn.private[:raw_body] == body
  end

  test "总量上限：累积超过 :length → {:more, <<>>, conn}（Parsers too_large → 413 契约）" do
    body = String.duplicate("x", 5_000)

    conn = conn(:post, "/webhook/wechat", body)

    # 旧实现返回 {:more, first_chunk, conn} 直传——测试失败（复审 F1 守卫）
    assert {:more, <<>>, conn} = @reader.read_body(conn, length: 1_000)
    assert conn.private[:raw_body] == nil
  end

  test "空 body：raw_body 为空串（不残留前次请求的 private）" do
    conn = conn(:post, "/webhook/wechat", "")

    assert {:ok, "", conn} = @reader.read_body(conn, [])
    assert conn.private[:raw_body] == ""
  end
end
