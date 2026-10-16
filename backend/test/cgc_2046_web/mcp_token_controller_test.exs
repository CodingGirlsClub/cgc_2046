defmodule Cgc2046Web.McpTokenControllerTest do
  @moduledoc """
  连接 token 凭自身核实身份与自撤销（U3，ADR-0022 / KTD3）：`GET /mcp/token`、`DELETE /mcp/token`。

  经真 endpoint 全链路（router → `:mcp` pipeline 的 McpAuthPlug → controller），Bearer 是 token
  本身而不是登录态。断言：

  - `GET` 返回与凭证一致的身份；账号标识只给脱敏值，原始邮箱 / 手机号不出响应体；
  - 无效或已撤销的凭证 401；
  - `DELETE` 撤销出示的这枚 token，之后它调 `GET /mcp/token` 与 MCP 工具都 401；
  - `DELETE` 只撤销自身：请求里点名的其他 token（路径 / query / body）一律不受影响。
  """
  # async: false —— 401 路径会累计 McpAuthPlug 的失败节流计数（全局 ETS 表），同 mcp_auth_plug_test
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.SignInFlow
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-token-controller-test","version":"0.0.0"}}})

  defp bearer(plain), do: put_req_header(build_conn(), "authorization", "Bearer #{plain}")

  defp post_mcp(plain, body, session_id \\ nil) do
    conn =
      plain
      |> bearer()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn

    post(conn, "/mcp", body)
  end

  defp revoked_at(token_id), do: Ash.get!(Token, token_id, authorize?: false).revoked_at

  describe "GET /mcp/token" do
    test "由 controller 处理（不进 MCP 传输层）：返回与凭证一致的身份，邮箱只给脱敏值" do
      user = Fixtures.register_user("mcp-token-who")

      user =
        user
        |> Ash.Changeset.for_update(:update_display_name, %{display_name: "小林"}, actor: user)
        |> Ash.update!()

      {:ok, token, plain} = Token.issue("我的 Mac", user, :learning_host)

      conn = get(bearer(plain), "/mcp/token")

      refute conn.resp_body =~ to_string(user.email)

      assert json_response(conn, 200) == %{
               "token_id" => token.id,
               "user_id" => user.id,
               "kind" => "learning_host",
               "display_name" => "小林",
               "masked_identifier" => "m***@example.com"
             }
    end

    test "手机号账号（无邮箱）：脱敏标识取手机号，未设显示名为 null" do
      phone = "+8615500003094"
      {:ok, user, _created?} = SignInFlow.find_or_create_user(phone)
      {:ok, _token, plain} = Token.issue("我的 Mac", user, :learning_host)

      conn = get(bearer(plain), "/mcp/token")

      refute conn.resp_body =~ phone

      assert %{"display_name" => nil, "masked_identifier" => "+86155****3094"} =
               json_response(conn, 200)
    end

    test "无效或已撤销的凭证 → 401" do
      user = Fixtures.register_user("mcp-token-who-revoked")
      {:ok, token, plain} = Token.issue("我的 Mac", user, :learning_host)
      {:ok, _} = Token.revoke(token.id, user)

      assert get(bearer("cgch_not_a_real_token"), "/mcp/token").status == 401
      assert get(bearer(plain), "/mcp/token").status == 401
    end
  end

  describe "DELETE /mcp/token" do
    test "撤销自身：之后同一凭证调 GET /mcp/token 与 MCP 工具都 401" do
      user = Fixtures.register_user("mcp-token-self-revoke")
      {:ok, token, plain} = Token.issue("我的 Mac", user, :learning_host)

      init = post_mcp(plain, @initialize_body)
      assert init.status == 200
      [session_id] = get_resp_header(init, "mcp-session-id")

      tool_call =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "get_learning_state", "arguments" => %{}}
        })

      # 对照：撤销前同一请求能到达工具层，之后的 401 来自撤销而不是请求本身
      assert post_mcp(plain, tool_call, session_id).status == 200

      assert delete(bearer(plain), "/mcp/token").status == 204
      assert revoked_at(token.id)

      assert get(bearer(plain), "/mcp/token").status == 401
      assert post_mcp(plain, tool_call, session_id).status == 401
    end

    test "只撤销出示的这枚：请求里点名的同账号其他 token 不受影响" do
      user = Fixtures.register_user("mcp-token-only-self")
      {:ok, presented, plain} = Token.issue("这台电脑", user, :learning_host)
      {:ok, other, _} = Token.issue("另一台电脑", user, :learning_host)

      conn =
        delete(bearer(plain), "/mcp/token?id=#{other.id}&token_id=#{other.id}", %{
          "id" => other.id,
          "token_id" => other.id
        })

      assert conn.status == 204
      assert revoked_at(presented.id)
      assert is_nil(revoked_at(other.id))

      # 路径里带 id 的形态不存在对应路由：不会撤销被点名的 token
      {:ok, third, third_plain} = Token.issue("第三台电脑", user, :learning_host)
      _ = delete(bearer(third_plain), "/mcp/token/#{other.id}")

      assert is_nil(revoked_at(other.id))
      assert is_nil(revoked_at(third.id))
    end
  end
end
