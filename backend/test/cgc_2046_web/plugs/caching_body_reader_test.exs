defmodule Cgc2046Web.Plugs.CachingBodyReaderTest do
  @moduledoc """
  017：raw body 缓存 reader 的分块累积守卫。

  回调体超过单次 `read_body` 上限时走 `{:more, chunk, conn}` 分块路径——
  此前只存最后一个块，前置分块静默丢失、渠道验签必败（fail-closed 的
  可用性悬崖）。此处用小 `read_length` 确定性强制分块路径。
  """

  use ExUnit.Case, async: true

  import Plug.Test

  @reader Cgc2046Web.Plugs.CachingBodyReader

  test "单块读取（默认 opts）：raw_body == 完整原文" do
    body = ~s({"event_type":"TRANSACTION.SUCCESS","amount":100})

    conn = conn(:post, "/webhook/wechat", body)

    assert {:ok, ^body, conn} = @reader.read_body(conn, [])
    assert conn.private[:raw_body] == body
  end

  test "多块读取（小 read_length 强制 {:more} 路径）：raw_body 累积为逐字节原文" do
    body = String.duplicate("x", 5_000) <> ~s({"out_trade_no":"oto-multi-chunk"})

    conn = conn(:post, "/webhook/wechat", body)

    assert {:ok, ^body, conn} =
             @reader.read_body(conn, read_length: 1_000, read_timeout: 5_000)

    assert conn.private[:raw_body] == body
  end

  test "空 body：raw_body 为空串（不残留前次请求的 private）" do
    conn = conn(:post, "/webhook/wechat", "")

    assert {:ok, "", conn} = @reader.read_body(conn, [])
    assert conn.private[:raw_body] == ""
  end
end
