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

  test "zip 内无 .csv 条目：返回空行集而非异常" do
    {:ok, {_, zip}} = :zip.create(~c"bill.zip", [{~c"readme.txt", "nope"}], [:memory])

    stub(fn conn -> Plug.Conn.send_resp(conn, 200, zip) end)

    assert {:ok, []} = Alipay.download_bill_file("http://cdn.example/bill.csv.zip")
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
