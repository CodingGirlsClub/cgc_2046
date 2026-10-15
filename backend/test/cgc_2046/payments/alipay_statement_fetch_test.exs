defmodule Cgc2046.Payments.AlipayStatementFetchTest do
  @moduledoc """
  账单腿回归（生产实证 2026-10-05~14：每日 03:23 对账 alipay 腿全数
  `:bill_fetch_failed`，对账连续降级为纯本地面）。

  根因：`fetch_statement` 用**签名 client**（`Client.get/1` → `Alipay.Requester`
  → `Alipay.Middleware.VerifySignature`）下载账单 CDN 文件。该中间件对 binary
  body 强制要求 alipay-nonce/signature/timestamp 三头并 JSON 解码；账单 CDN
  响应两者皆无 → 一律 `{:error, :invaild_response}`。

  修复：账单下载走独立 `Req`（无签名中间件），并支持渠道返回的 zip 形态。
  #1105 补：账单明细是 GBK 无 BOM，下载后走 codepagex CP936 转码再解析（此处
  两条 GBK 用例钉住转码与行键命中）。本测试直接驱动 `download_bill_file/1`——
  它是不依赖 SDK/Tesla 的纯下载腿，因此测试零外呼、可离线跑。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.Payments.Providers.Alipay

  @csv """
  支付宝交易号,商户订单号,业务类型,商品名称,创建时间,完成时间,门店编号,门店名称,操作员,终端号,对方账户,订单金额,商家实收,支付宝红包,,用户支付的金额,,退费金额,交易状态
  2026100122001,CGC-OTO-1,trade,报名费,2026-10-01 10:00:00,2026-10-01 10:00:05,,,,,foo@bar.com,199.00,199.00,0.00,,199.00,,0.00,交易成功
  """

  # 上面 @csv 的同形内容（多说明行与合计行，官方真实形态）的 **GBK 无 BOM** 字节。
  # 硬写字节而非测试内现编（Codepagex.from_string），避免被测解码与夹具构造共用
  # 同一张映射表而互相掩盖错位。
  @gbk_bill <<
    35,
    214,
    167,
    184,
    182,
    177,
    166,
    213,
    203,
    181,
    165,
    195,
    247,
    207,
    184,
    178,
    233,
    209,
    175,
    10,
    35,
    213,
    203,
    186,
    197,
    58,
    91,
    102,
    111,
    111,
    64,
    101,
    120,
    97,
    109,
    112,
    108,
    101,
    46,
    99,
    111,
    109,
    93,
    10,
    35,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    189,
    187,
    210,
    215,
    188,
    199,
    194,
    188,
    195,
    247,
    207,
    184,
    193,
    208,
    177,
    237,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    45,
    10,
    214,
    167,
    184,
    182,
    177,
    166,
    189,
    187,
    210,
    215,
    186,
    197,
    44,
    201,
    204,
    187,
    167,
    182,
    169,
    181,
    165,
    186,
    197,
    44,
    210,
    181,
    206,
    241,
    192,
    224,
    208,
    205,
    44,
    201,
    204,
    198,
    183,
    195,
    251,
    179,
    198,
    44,
    180,
    180,
    189,
    168,
    202,
    177,
    188,
    228,
    44,
    205,
    234,
    179,
    201,
    202,
    177,
    188,
    228,
    44,
    195,
    197,
    181,
    234,
    177,
    224,
    186,
    197,
    44,
    195,
    197,
    181,
    234,
    195,
    251,
    179,
    198,
    44,
    178,
    217,
    215,
    247,
    212,
    177,
    44,
    214,
    213,
    182,
    203,
    186,
    197,
    44,
    182,
    212,
    183,
    189,
    213,
    203,
    187,
    167,
    44,
    182,
    169,
    181,
    165,
    189,
    240,
    182,
    238,
    44,
    201,
    204,
    188,
    210,
    202,
    181,
    202,
    213,
    44,
    214,
    167,
    184,
    182,
    177,
    166,
    186,
    236,
    176,
    252,
    44,
    44,
    211,
    195,
    187,
    167,
    214,
    167,
    184,
    182,
    181,
    196,
    189,
    240,
    182,
    238,
    44,
    44,
    205,
    203,
    183,
    209,
    189,
    240,
    182,
    238,
    44,
    189,
    187,
    210,
    215,
    215,
    180,
    204,
    172,
    10,
    50,
    48,
    50,
    54,
    49,
    48,
    48,
    49,
    50,
    50,
    48,
    48,
    49,
    44,
    67,
    71,
    67,
    45,
    79,
    84,
    79,
    45,
    49,
    44,
    116,
    114,
    97,
    100,
    101,
    44,
    177,
    168,
    195,
    251,
    183,
    209,
    44,
    50,
    48,
    50,
    54,
    45,
    49,
    48,
    45,
    48,
    49,
    32,
    49,
    48,
    58,
    48,
    48,
    58,
    48,
    48,
    44,
    50,
    48,
    50,
    54,
    45,
    49,
    48,
    45,
    48,
    49,
    32,
    49,
    48,
    58,
    48,
    48,
    58,
    48,
    53,
    44,
    44,
    44,
    44,
    44,
    102,
    111,
    111,
    64,
    98,
    97,
    114,
    46,
    99,
    111,
    109,
    44,
    49,
    57,
    57,
    46,
    48,
    48,
    44,
    49,
    57,
    57,
    46,
    48,
    48,
    44,
    48,
    46,
    48,
    48,
    44,
    44,
    49,
    57,
    57,
    46,
    48,
    48,
    44,
    44,
    48,
    46,
    48,
    48,
    44,
    189,
    187,
    210,
    215,
    179,
    201,
    185,
    166,
    10,
    35,
    186,
    207,
    188,
    198,
    58,
    49,
    177,
    202,
    32,
    32,
    32,
    32,
    189,
    187,
    210,
    215,
    189,
    240,
    182,
    238,
    58,
    49,
    57,
    57,
    46,
    48,
    48,
    212,
    170,
    10
  >>

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

  test "GBK 编码账单（支付宝生产形态）→ CP936 转码出行（#1105）" do
    # 支付宝账单明细为 **GBK 无 BOM**（官方帮助中心账单说明 + 多份实测印证）。
    # #1097 的降级闸已修通下载；#1105 用 codepagex 的 CP936 表转码。行键必须命中
    # worker 消费的 UTF-8 常量（@alipay_*_key），否则 normalize_rows 静默丢行。
    assert byte_size(@gbk_bill) == 459, "硬写 GBK 夹具被截断（粘贴完整性闸）"
    refute String.valid?(@gbk_bill), "前提：夹具不是合法 UTF-8（确是 GBK 形态）"

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, @gbk_bill) end)

    assert {:ok, [row]} = Alipay.download_bill_file("http://cdn.example/bill.csv")
    assert row["商户订单号"] == "CGC-OTO-1"
    assert row["订单金额"] == "199.00"
    assert row["交易状态"] == "交易成功"
  end

  test "zip 内 CSV 为 GBK：解包后同样转码出行" do
    {:ok, {_, zip}} = :zip.create(~c"bill.zip", [{~c"a.csv", @gbk_bill}], [:memory])

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zip) end)

    assert {:ok, [row]} = Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
    assert row["商户订单号"] == "CGC-OTO-1"
  end

  test "乱字节（非 UTF-8 非 GBK）→ :bill_fetch_failed（降级语义保留，不得拿乱码行当账）" do
    # 0xFF 不是 CP936 合法 lead；0x81 是 lead 但 0x30 不在 trail 范围（0x40-0xFE）。
    garbage = <<0xFF, 0xFF, 0xFE, 0x81, 0x30>>

    refute String.valid?(garbage), "前提：不是合法 UTF-8"

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, garbage) end)

    assert {:error, :bill_fetch_failed} = Alipay.download_bill_file("http://cdn.example/bill.csv")
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
