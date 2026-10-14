defmodule Cgc2046.Payments.AlipayStatementFetchTest do
  @moduledoc """
  账单腿回归（生产实证 2026-10-05~14：每日 03:23 对账 alipay 腿全数
  `:bill_fetch_failed`，对账连续降级为纯本地面）。

  根因：`fetch_statement` 用**签名 client**（`Client.get/1` → `Alipay.Requester`
  → `Alipay.Middleware.VerifySignature`）下载账单 CDN 文件。该中间件对 binary
  body 强制要求 alipay-nonce/signature/timestamp 三头并 JSON 解码；账单 CDN
  响应两者皆无 → 一律 `{:error, :invaild_response}`。

  修复：账单下载走独立 `Req`（无签名中间件），并支持渠道返回的 zip 形态。
  本测试直接驱动 `download_bill_file/1`——它是不依赖 SDK/Tesla 的纯下载腿，
  因此测试零外呼、可离线跑。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Payments.Providers.Alipay

  @csv """
  支付宝交易号,商户订单号,业务类型,商品名称,创建时间,完成时间,门店编号,门店名称,操作员,终端号,对方账户,订单金额,商家实收,支付宝红包,,用户支付的金额,,退费金额,交易状态
  2026100122001,CGC-OTO-1,trade,报名费,2026-10-01 10:00:00,2026-10-01 10:00:05,,,,,foo@bar.com,199.00,199.00,0.00,,199.00,,0.00,交易成功
  """

  setup do
    prev = Application.get_env(:cgc_2046, :alipay_bill_req_plug)
    Application.put_env(:cgc_2046, :alipay_bill_req_plug, {Req.Test, Cgc2046.AlipayBillStub})

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cgc_2046, :alipay_bill_req_plug, prev),
        else: Application.delete_env(:cgc_2046, :alipay_bill_req_plug)
    end)

    :ok
  end

  test "CDN 返回 CSV 正文：直接出行（不经签名中间件、无 ack 头要求）" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, @csv) end)

    assert {:ok, [row]} = Alipay.download_bill_file("http://cdn.example/bill.csv")
    assert row["商户订单号"] == "CGC-OTO-1"
    assert row["订单金额"] == "199.00"
  end

  test "CDN 返回 zip（渠道 csv.zip 形态）：解包出 CSV 再出行" do
    {:ok, {_, zip}} =
      :zip.create(~c"bill.zip", [{~c"20881218676211490156_20261001.csv", @csv}], [:memory])

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zip) end)

    assert {:ok, [row]} = Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
    assert row["商户订单号"] == "CGC-OTO-1"
  end

  test "zip 内无 .csv 条目 → :bill_fetch_failed（不得降级成「账单完整但零行」）" do
    {:ok, {_, zip}} = :zip.create(~c"bill.zip", [{~c"readme.txt", "nope"}], [:memory])

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zip) end)

    assert {:error, :bill_fetch_failed} =
             Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
  end

  test "zip 损坏/截断 → :bill_fetch_failed（不得当成零行）" do
    {:ok, {_, zip}} = :zip.create(~c"bill.zip", [{~c"a.csv", @csv}], [:memory])
    truncated = binary_part(zip, 0, div(byte_size(zip), 2))

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, truncated) end)

    assert {:error, :bill_fetch_failed} =
             Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
  end

  test "GBK 编码账单（支付宝生产形态）→ :bill_fetch_failed，不得拿乱码行当账" do
    # 支付宝账单明细为 **GBK 无 BOM**（官方帮助中心账单说明 + 多份实测印证），
    # 而两个渠道共用的 parse_statement_csv 产出的是 UTF-8 中文表头键。若把 GBK
    # 字节直接喂进解析，中文表头键不会等于 worker 消费的 UTF-8 常量
    # （normalize_rows 的 `status when is_binary` 守卫恒失败）→ 整渠道行静默丢弃，
    # 却返回 {:ok, rows} 让 worker 当「账单完整」→ 假 local_paid_missing + 全量
    # sweep 删真差异。该破坏性后果比降级更差，故解码无法验证时一律按拉取失败。
    # 「商户订单号」的 GBK 字节（手写，避免引入编码库依赖）
    gbk =
      <<0xC9, 0xCC, 0xBB, 0xA7, 0xB6, 0xA9, 0xB5, 0xA5, 0xBA, 0xC5>> <> ",199.00,TRADE_SUCCESS\n"

    refute String.valid?(gbk), "构造的字节不是合法 UTF-8（GBK 形态）"

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, gbk) end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/bill.csv")
  end

  test "zip 内 CSV 为 GBK → 同样 :bill_fetch_failed（解包后仍要过编码关）" do
    gbk =
      <<0xC9, 0xCC, 0xBB, 0xA7, 0xB6, 0xA9, 0xB5, 0xA5, 0xBA, 0xC5>> <> ",199.00,TRADE_SUCCESS\n"

    {:ok, {_, zip}} = :zip.create(~c"bill.zip", [{~c"a.csv", gbk}], [:memory])

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zip) end)

    assert {:error, :bill_fetch_failed} =
             Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
  end

  test "合法零交易账单（有表头无数据行）→ {:ok, []}，不得误判为拉取失败" do
    # 官方形态：说明行 + 表头 + 合计行。有表头即「识别成功」，只是当日无交易。
    zero_trade = """
    #支付宝账单明细查询
    #账号:[foo@example.com]
    #---------------------------------交易记录明细列表---------------------------------
    支付宝交易号,商户订单号,业务类型,商品名称,创建时间,完成时间,门店编号,门店名称,操作员,终端号,对方账户,订单金额,商家实收,支付宝红包,,用户支付的金额,,退费金额,交易状态
    #合计:0笔    交易金额:0.00元
    """

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zero_trade) end)

    assert {:ok, []} = Alipay.download_bill_file("http://cdn.example/bill.csv")
  end

  test "HTTP 200 + HTML 错误页 → :bill_fetch_failed（不得当成合法空账单）" do
    # 实测：`String.valid?` 对 HTML 为 true，故编码闸挡不住它；若只看「解析出行集」
    # 会得到 {:ok, []} → worker 当「账单完整」→ 假 local_paid_missing + 全量 sweep。
    html = "<!DOCTYPE html><html><body>502 Bad Gateway</body></html>"

    assert String.valid?(html), "前提：HTML 能通过编码闸"

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, html) end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/bill.csv")
  end

  test "HTTP 200 + 空正文 → :bill_fetch_failed" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/bill.csv")
  end

  test "表头缺必需列（架构变更/错文件）→ :bill_fetch_failed" do
    wrong = "交易号,金额,状态\n1,2,3\n"

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, wrong) end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/bill.csv")
  end

  test "CDN 非 200 → :bill_fetch_failed" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/x.csv")
  end

  test "CDN 连接失败 → :bill_fetch_failed（不抛）" do
    Req.Test.stub(Cgc2046.AlipayBillStub, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/x.csv")
  end

  defp stub(fun), do: Req.Test.stub(Cgc2046.AlipayBillStub, fun)
end
