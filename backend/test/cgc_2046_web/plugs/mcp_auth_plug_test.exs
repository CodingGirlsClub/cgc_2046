defmodule Cgc2046Web.Plugs.McpAuthPlugTest do
  @moduledoc """
  MCP Bearer 鉴权 plug 测试（D13 / KTD8 双凭证装配）：

  - 静态连接 token：有效 → `assign(:current_user, user)`；缺失/格式错误/无效/已撤销 → 401
  - OAuth access token：签名校验 + **每次调用回查授权活跃性**（撤销/闲置即时
    401），两者都落到 `current_user` 且带凭证类型归因（工具审计用）
  - 401 一律带 RFC 9728 `resource_metadata` 发现头与 RFC 6750 error 语义
  - 失败节流按凭证类型分桶：OAuth 失败与静态 token 失败互不污染
  """
  # async: false —— 401 失败路径会累计 McpAuthPlug 节流计数（全局 ETS 表），
  # 与 mcp_auth_rate_limit_test 的 put_env 低阈值窗口并发会互相污染（同
  # graphql_accept_invitation_test 对 graphql_invitation_rate_limit_test 的处理）。
  # OAuth 布置经真路由，且工具/session 在 Task 进程跑（sandbox shared）。
  use Cgc2046Web.ConnCase, async: false

  alias AshAuthentication.Phoenix.Oauth2Server.Errors
  alias Cgc2046.Accounts.OAuthRefreshToken
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046.OAuthFixtures, as: OAuth
  alias Cgc2046.Oauth2Server
  alias Cgc2046Web.Plugs.McpAuthPlug

  defp issue_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "plug test"}, actor: user)
      |> Ash.create()

    {token, token.__metadata__[:plain_token]}
  end

  defp call(conn), do: McpAuthPlug.call(conn, McpAuthPlug.init([]))

  defp call_with(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> call()
  end

  test "有效 Bearer token → current_user 注入，请求放行" do
    user = Fixtures.register_user("mcp-plug-ok")
    {_token, plain} = issue_token(user)

    conn = call_with(plain)

    refute conn.halted
    assert conn.assigns[:current_user].id == user.id
    assert conn.assigns[:mcp_credential] == %{type: :token}
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
    conn = call_with("cgc_not_a_real_token")

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

    conn = call_with(plain)

    assert conn.halted
    assert conn.status == 401
  end

  test "401 带 RFC 9728 resource_metadata 与 RFC 6750 error（宿主发现授权服务器）" do
    conn = call(build_conn())

    assert conn.status == 401
    [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge =~ "Bearer "
    assert challenge =~ ~s(error="invalid_token")

    assert challenge =~
             ~s(resource_metadata="#{Errors.resource_metadata_url(Oauth2Server)}")

    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
  end

  describe "OAuth 凭证（KTD8）" do
    test "有效 OAuth access token → current_user + 凭证归因，请求放行" do
      user = Fixtures.register_user("mcp-plug-oauth")
      tokens = OAuth.authorize!(user)

      conn = call_with(tokens["access_token"])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
      assert conn.assigns[:mcp_credential] == %{type: :oauth}
    end

    test "令牌可用但授权已撤销 → 401（活跃性回查，纯签名校验做不到）" do
      user = Fixtures.register_user("mcp-plug-oauth-revoked")
      tokens = OAuth.authorize!(user)

      assert :ok = OAuthRefreshToken.revoke_authorization(user.id, tokens["client_id"])

      conn = call_with(tokens["access_token"])

      assert conn.halted
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "授权闲置超过窗口 → 401" do
      user = Fixtures.register_user("mcp-plug-oauth-idle")
      tokens = OAuth.authorize!(user)

      OAuth.expire_authorization!(tokens)

      conn = call_with(tokens["access_token"])

      assert conn.halted
      assert conn.status == 401
    end

    test "非本服务器签发的 JWT（伪造/他源）→ 401" do
      # 形态是 JWT（三段）→ 走 OAuth 分支；签名校验失败即拒
      conn = call_with("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJub2JvZHkifQ.forged")

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "失败节流分桶（OAuth vs 静态 token 互不污染）" do
    setup do
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
      Application.put_env(:cgc_2046, McpAuthPlug, max_attempts: 2)

      on_exit(fn ->
        :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
        Application.put_env(:cgc_2046, McpAuthPlug, max_attempts: 999_999)
      end)

      :ok
    end

    test "OAuth 桶吃满后 OAuth 401→429，静态 token 桶仍 401，有效静态 token 照常放行" do
      user = Fixtures.register_user("mcp-plug-bucket")
      {_token, plain} = issue_token(user)

      for i <- 1..2 do
        assert call_with("header-#{i}.payload-#{i}.signature").status == 401
      end

      # OAuth 桶超限
      assert call_with("header.payload.signature").status == 429

      # 静态 token 桶独立：失败仍 401（不被 OAuth 桶的 429 污染）
      assert call_with("cgc_invalid_static").status == 401

      # 有效静态 token 不受任何节流影响
      conn = call_with(plain)

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end

    test "静态 token 桶吃满后静态 401→429，OAuth 桶不受影响" do
      user = Fixtures.register_user("mcp-plug-bucket-reverse")
      tokens = OAuth.authorize!(user)

      for i <- 1..2 do
        assert call_with("cgc_invalid_#{i}").status == 401
      end

      assert call_with("cgc_invalid_3").status == 429

      # OAuth 桶独立：有效 OAuth 凭证照常放行
      conn = call_with(tokens["access_token"])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end
  end
end
