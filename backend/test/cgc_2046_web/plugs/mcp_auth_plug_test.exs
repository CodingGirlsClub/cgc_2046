defmodule Cgc2046Web.Plugs.McpAuthPlugTest do
  @moduledoc """
  MCP Bearer 鉴权 plug 测试（D13）：

  - 有效 token → assign(:current_user, user)
  - 缺失/格式错误/无效/已撤销 → 401 + WWW-Authenticate
  """
  # async: false —— 401 失败路径会累计 McpAuthPlug 节流计数（全局 ETS 表），
  # 与 mcp_auth_rate_limit_test 的 put_env 低阈值窗口并发会互相污染（同
  # graphql_accept_invitation_test 对 graphql_invitation_rate_limit_test 的处理）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046Web.Plugs.McpAuthPlug

  defp issue_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "plug test"}, actor: user)
      |> Ash.create()

    {token, token.__metadata__[:plain_token]}
  end

  defp call(conn), do: McpAuthPlug.call(conn, McpAuthPlug.init([]))

  test "有效 Bearer token → current_user 注入，请求放行" do
    user = Fixtures.register_user("mcp-plug-ok")
    {_token, plain} = issue_token(user)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain}")
      |> call()

    refute conn.halted
    assert conn.assigns[:current_user].id == user.id
  end

  test "无 Authorization header → 401 + WWW-Authenticate" do
    conn = call(build_conn())

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") != []
  end

  test "非 Bearer scheme → 401" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Basic abc123")
      |> call()

    assert conn.halted
    assert conn.status == 401
  end

  test "无效 token → 401" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer cgc_not_a_real_token")
      |> call()

    assert conn.halted
    assert conn.status == 401
  end

  test "已撤销 token → 401" do
    user = Fixtures.register_user("mcp-plug-revoked")
    {token, plain} = issue_token(user)

    {:ok, _} =
      token
      |> Ash.Changeset.for_update(:revoke, %{}, actor: user)
      |> Ash.update()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain}")
      |> call()

    assert conn.halted
    assert conn.status == 401
  end
end
