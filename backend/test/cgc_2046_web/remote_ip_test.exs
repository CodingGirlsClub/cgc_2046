defmodule Cgc2046Web.RemoteIpTest do
  @moduledoc """
  #278：代理链 client IP 解析的行为锚定。

  生产经编译期 Mix.env 分支注入 @trusted_proxies（172.16.0.0/12 等）+
  x-forwarded-for 头解析；test 编译分支为空集。测试以 RemoteIp.Options
  的生产形态直接验证解析语义——伪造 XFF 左侧条目不可提权（从右往左
  取第一个非信任 IP）。
  """

  use Cgc2046Web.ConnCase, async: true

  # 与 endpoint @trusted_proxies 生产分支同值（改一处须同步另一处）
  @prod_proxies ["172.16.0.0/12", "127.0.0.1", "::1"]

  defp parse(conn, opts) do
    RemoteIp.call(conn, RemoteIp.init(opts))
  end

  defp conn_with(peer, xff) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, peer)

    if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
  end

  @prod_opts [headers: ["x-forwarded-for"], proxies: @prod_proxies]
  @dev_opts [headers: [], proxies: []]

  describe "生产形态（可信代理网段）" do
    test "kamal-proxy 单跳：XFF 里的真实 client 被解析" do
      conn =
        conn_with({172, 18, 0, 3}, "113.97.104.55")
        |> parse(@prod_opts)

      assert conn.remote_ip == {113, 97, 104, 55}
    end

    test "Next rewrite 第二跳：XFF 链 = client, proxy——解析出 client" do
      conn =
        conn_with({172, 18, 0, 3}, "113.97.104.55, 172.18.0.7")
        |> parse(@prod_opts)

      assert conn.remote_ip == {113, 97, 104, 55}
    end

    test "伪造 XFF 左侧条目不可提权（攻击者真实 IP 在右侧）" do
      # 攻击者（1.2.3.4）直连 proxy，伪造 XFF 前缀若干受害者 IP；
      # proxy append 其真实 peer 在最右侧——解析取第一个非信任 IP = 1.2.3.4
      conn =
        conn_with({172, 18, 0, 3}, "8.8.8.8, 1.1.1.1, 1.2.3.4")
        |> parse(@prod_opts)

      assert conn.remote_ip == {1, 2, 3, 4}
    end

    test "全链可信（健康探针）落回 socket peer" do
      conn =
        conn_with({127, 0, 0, 1}, nil)
        |> parse(@prod_opts)

      assert conn.remote_ip == {127, 0, 0, 1}
    end
  end

  describe "test/dev 形态（无代理）" do
    test "peer 即真实 IP，XFF 头不解析（伪造无效）" do
      # 与 endpoint test 分支同构：headers 空——RemoteIp 不读任何转发头
      conn =
        conn_with({192, 168, 1, 50}, "6.6.6.6")
        |> parse(@dev_opts)

      assert conn.remote_ip == {192, 168, 1, 50}
    end
  end
end
