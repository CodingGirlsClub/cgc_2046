defmodule Cgc2046Web.Plugs.McpProtocolCompatPlugTest do
  @moduledoc """
  MCP-Protocol-Version 兼容 shim 测试（walkthrough 发现的阻塞 bug）：

  单元级（call 直测）：
  - header 恰为 2024-11-05 → 删除（让 anubis 走 header 缺失的向后兼容路径）
  - 其它版本值 → 原样透传
  - 无 header → 不变

  集成级（经 endpoint + 真实 token 到 anubis）：
  - 2024-11-05 → initialize 200 + mcp-session-id（修复前为 400）
  - 1999-01-01 → 仍 400 Unsupported（行为不变）
  - 无 header → 200（行为不变）
  """
  # async: false —— 未认证集成用例走 401 失败路径，累计 McpAuthPlug 节流计数
  # （全局 ETS 表），与 mcp_auth_rate_limit_test 的 put_env 低阈值窗口并发会
  # 互相污染（同 graphql_accept_invitation_test 的处理）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046Web.Plugs.McpProtocolCompatPlug

  @legacy_version "2024-11-05"

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"compat-test","version":"0.0.0"}}})

  defp issue_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "compat plug test"}, actor: user)
      |> Ash.create()

    {token, token.__metadata__[:plain_token]}
  end

  defp call_plug(conn), do: McpProtocolCompatPlug.call(conn, McpProtocolCompatPlug.init([]))

  # ---- 单元级 ----

  test "call：header 恰为 2024-11-05 → 删除" do
    conn =
      build_conn()
      |> put_req_header("mcp-protocol-version", @legacy_version)
      |> call_plug()

    assert get_req_header(conn, "mcp-protocol-version") == []
  end

  test "call：其它版本值原样透传" do
    conn =
      build_conn()
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> call_plug()

    assert get_req_header(conn, "mcp-protocol-version") == ["1999-01-01"]
  end

  test "call：无 header 不变" do
    conn = call_plug(build_conn())

    assert get_req_header(conn, "mcp-protocol-version") == []
  end

  test "call：多值 header（2024-11-05 在前）不进入 shim，原样透传" do
    conn =
      %Plug.Conn{
        build_conn()
        | req_headers: [
            {"mcp-protocol-version", "2024-11-05"},
            {"mcp-protocol-version", "1999-01-01"}
          ]
      }
      |> call_plug()

    assert get_req_header(conn, "mcp-protocol-version") == ["2024-11-05", "1999-01-01"]
  end

  test "call：多值 header（2024-11-05 在后）不进入 shim，原样透传" do
    conn =
      %Plug.Conn{
        build_conn()
        | req_headers: [
            {"mcp-protocol-version", "1999-01-01"},
            {"mcp-protocol-version", "2024-11-05"}
          ]
      }
      |> call_plug()

    assert get_req_header(conn, "mcp-protocol-version") == ["1999-01-01", "2024-11-05"]
  end

  # ---- 集成级（经 endpoint 全链路：router → shim → auth → anubis）----

  defp post_initialize(plain_token, protocol_version) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain_token}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      if protocol_version do
        put_req_header(conn, "mcp-protocol-version", protocol_version)
      else
        conn
      end

    post(conn, "/mcp", @initialize_body)
  end

  test "集成：旧版 2024-11-05 header 经 shim 后 initialize 成功" do
    user = Fixtures.register_user("compat-legacy-ok")
    {_token, plain} = issue_token(user)

    conn = post_initialize(plain, @legacy_version)

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") != []
  end

  test "集成：其它不支持版本（1999-01-01）仍 400 Unsupported" do
    user = Fixtures.register_user("compat-bad-version")
    {_token, plain} = issue_token(user)

    conn = post_initialize(plain, "1999-01-01")

    assert conn.status == 400
    assert conn.resp_body =~ "Unsupported MCP-Protocol-Version"
  end

  test "集成：无 header 行为不变（200）" do
    user = Fixtures.register_user("compat-no-header")
    {_token, plain} = issue_token(user)

    conn = post_initialize(plain, nil)

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") != []
  end

  # ---- shim 与 auth 边界锁：shim 只动 header，不削弱鉴权 ----

  defp post_initialize_unauthenticated(protocol_version, auth_header) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", protocol_version)

    conn =
      if auth_header do
        put_req_header(conn, "authorization", auth_header)
      else
        conn
      end

    post(conn, "/mcp", @initialize_body)
  end

  test "边界：旧版 header + 无效 Bearer → 仍 401 + WWW-Authenticate" do
    conn = post_initialize_unauthenticated(@legacy_version, "Bearer cgc_not_a_real_token")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "边界：旧版 header + 缺失 Bearer → 仍 401 + WWW-Authenticate" do
    conn = post_initialize_unauthenticated(@legacy_version, nil)

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end
end
