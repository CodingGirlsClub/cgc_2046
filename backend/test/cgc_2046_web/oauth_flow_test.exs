defmodule Cgc2046Web.OAuthFlowTest do
  @moduledoc """
  MCP OAuth 授权服务器全流程测试（U3，KTD1/KTD2/KTD8）：in-process ConnTest 走
  **真路由**（真 endpoint → router → 库的 ConsentRouter / ProtocolRouter → 库核心
  → Ash 资源），不 mock 授权服务器内部；布置入口见 `Cgc2046.OAuthFixtures`。

  覆盖：

  - 发现端点：RFC 9728 PRM（`/.well-known/oauth-protected-resource`）与 RFC 8414
    元数据（`/.well-known/oauth-authorization-server`）；`/.well-known` 挂载只服务
    元数据（写端点不在该前缀下暴露）
  - DCR（RFC 7591）：缺 `application_type` 被接受、loopback 任意端口通过、
    非 loopback 拒绝、`localhost` 与 `127.0.0.1` 不交叉匹配
  - 授权码 + PKCE S256：授权页 GET → 同意 POST → 码换令牌 → 令牌可用于 `/mcp`
    并正确归属用户；refresh 轮换与 reuse 检测
  - 错误语义：错误 verifier / 错误 redirect_uri / 无效码 / 撤销后的 refresh 一律
    `invalid_grant`（U2 实测：宿主以 invalid_grant 判定「需重新授权」）
  - 撤销：RFC 7009 `/oauth/revoke` 与 web 撤销面（`revoke_authorization/2`）都令
    同一授权的全部令牌失效（级联 refresh），且**下一次调用即 401**（活跃性回查，
    不依赖令牌自然过期）
  - 打包路径：预注册固定 client_id 完成完整授权（不经过注册端点）
  - 凭证类型归因：工具调用审计落 `credential_type`（OAuth vs 静态 token）

  async: false —— 工具执行在 anubis session 的 Task 进程跑（sandbox shared 模式），
  且失败节流用共享 ETS 表。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.{OAuthClient, OAuthConsent, OAuthRefreshToken}
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.{Token, ToolCallLog}
  alias Cgc2046.OAuthFixtures, as: OAuth
  alias Cgc2046.Oauth2Server

  require Ash.Query

  @loopback_redirect "http://127.0.0.1:19876/mcp/oauth/callback"

  defp last_log!(tool) do
    ToolCallLog
    |> Ash.Query.filter(tool == ^tool)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  # ---- 发现端点 ----

  describe "发现端点（KTD2 单一配置源）" do
    test "PRM 落 resource 原点根路径，resource / authorization_servers / scopes 与单一配置源一致" do
      conn = get(build_conn(), "/.well-known/oauth-protected-resource")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["resource"] == OAuth.resource_url()
      assert body["authorization_servers"] == [OAuth.issuer_url()]
      assert body["scopes_supported"] == [Oauth2Server.scope()]
      assert body["bearer_methods_supported"] == ["header"]
    end

    test "RFC 8414 元数据：端点由 issuer 推导，DCR 开启即广告注册端点" do
      conn = get(build_conn(), "/.well-known/oauth-authorization-server")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["issuer"] == OAuth.issuer_url()
      assert body["authorization_endpoint"] == OAuth.issuer_url() <> "/oauth/authorize"
      assert body["token_endpoint"] == OAuth.issuer_url() <> "/oauth/token"
      assert body["revocation_endpoint"] == OAuth.issuer_url() <> "/oauth/revoke"
      assert body["registration_endpoint"] == OAuth.issuer_url() <> "/oauth/register"
      assert body["code_challenge_methods_supported"] == ["S256"]
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
      assert body["scopes_supported"] == [Oauth2Server.scope()]
      assert body["authorization_response_iss_parameter_supported"] == true
    end

    test "/.well-known 挂载只服务元数据：写端点不在该前缀下暴露" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/.well-known/oauth/token", %{"grant_type" => "refresh_token"})

      assert conn.status == 404
    end
  end

  # ---- DCR ----

  describe "动态客户端注册（RFC 7591）" do
    test "缺 application_type 的注册被接受（宿主不发送该字段）" do
      {conn, body} = OAuth.register_client([@loopback_redirect])

      assert conn.status == 201
      assert is_binary(body["client_id"])
      assert body["redirect_uris"] == [@loopback_redirect]
      assert body["token_endpoint_auth_method"] == "none"

      assert {:ok, client} = Ash.get(OAuthClient, body["client_id"], authorize?: false)
      assert client.client_name == "opencode"
    end

    test "loopback 回调任意端口通过（127.0.0.1 / ::1 / localhost）" do
      for uri <- [
            "http://127.0.0.1:19876/mcp/oauth/callback",
            "http://127.0.0.1:54321/cb",
            "http://[::1]:9999/cb",
            "http://localhost:7777/cb"
          ] do
        {conn, _body} = OAuth.register_client([uri])
        assert conn.status == 201, "expected #{uri} to be accepted"
      end
    end

    test "非 loopback 回调一律拒绝（本期政策），不落客户端行" do
      # 两层拒绝，错误码按先命中者返回：
      # - http 非 loopback → 库自带校验（RFC 7591 §3.2.2 的 invalid_redirect_uri）
      # - https 任意 host → 客户端资源上的 loopback 不变量（invalid_client_metadata）
      # 二者都拒绝；loopback 不变量在客户端行的唯一写入路径上，无法经 HTTP 层绕过。
      cases = %{
        "https://evil.example.com/cb" => "invalid_client_metadata",
        "http://192.168.1.10:19876/cb" => "invalid_redirect_uri",
        "http://myhost.local:19876/cb" => "invalid_redirect_uri"
      }

      for {uri, expected_code} <- cases do
        {conn, body} = OAuth.register_client([uri])

        assert conn.status == 400, "expected #{uri} to be rejected"
        assert body["error"] == expected_code
      end

      assert Ash.count!(OAuthClient, authorize?: false) == 0
    end

    test "localhost 与 127.0.0.1 不交叉匹配（授权回调必须精确落在注册值上）" do
      client_id = OAuth.dcr_client(["http://127.0.0.1:19876/mcp/oauth/callback"])
      user = Fixtures.register_user("oauth-redirect-mismatch")

      conn =
        user.email
        |> OAuth.sign_in_cookie()
        |> OAuth.consent_get(
          client_id,
          "http://localhost:19876/mcp/oauth/callback",
          OAuth.pkce_verifier()
        )

      # 不匹配已注册值时禁止重定向（RFC 6749 §4.1.2.1：未验证 URI 不回跳），直接 400
      assert conn.status == 400
      assert conn.resp_body =~ "redirect"
    end

    test "loopback 端口可变（RFC 8252 §7.3）：注册端口与授权端口不同仍通过" do
      client_id = OAuth.dcr_client(["http://127.0.0.1:19876/mcp/oauth/callback"])
      user = Fixtures.register_user("oauth-port-vary")

      conn =
        user.email
        |> OAuth.sign_in_cookie()
        |> OAuth.consent_get(
          client_id,
          "http://127.0.0.1:54321/mcp/oauth/callback",
          OAuth.pkce_verifier()
        )

      assert conn.status == 200
    end

    test "缺 redirect_uris 拒绝" do
      {conn, body} = OAuth.register_client([])
      assert conn.status == 400
      assert body["error"] == "invalid_client_metadata"
    end
  end

  # ---- 授权码 + PKCE ----

  describe "授权码 + PKCE 全流程" do
    test "同意 → 码 → 令牌 → /mcp 调用并正确归属用户" do
      user = Fixtures.register_user("oauth-happy")
      tokens = OAuth.authorize!(user)

      assert tokens["token_type"] == "Bearer"
      assert tokens["scope"] == Oauth2Server.scope()
      assert is_integer(tokens["expires_in"]) and tokens["expires_in"] > 0
      assert is_binary(tokens["refresh_token"])

      # 令牌真能过 /mcp 认证链，并归属签发者
      session_id = OAuth.open_session(tokens["access_token"])
      assert is_binary(session_id)

      %{"result" => %{"content" => [%{"text" => text}]}} =
        OAuth.call_tool(tokens["access_token"], session_id, "list_my_workspaces", %{})

      assert %{"workspaces" => _} = Jason.decode!(text)

      log = last_log!("list_my_workspaces")
      assert log.user_id == user.id
      assert log.credential_type == :oauth

      # 活跃性回查同时写入该授权的最近使用时间（首公里「已连接」判定源，KTD3/U5）
      authorization =
        OAuthRefreshToken
        |> Ash.Query.filter(
          user_id == ^user.id and client_id == ^tokens["client_id"] and is_nil(rotated_to_id)
        )
        |> Ash.read_one!(authorize?: false)

      assert authorization.last_used_at
      refute authorization.revoked_at
    end

    test "refresh 轮换发新令牌，旧 refresh 复用被拒并撤整链" do
      user = Fixtures.register_user("oauth-refresh")
      tokens = OAuth.authorize!(user)

      conn = OAuth.refresh_token_request(tokens["refresh_token"], tokens["client_id"])
      assert conn.status == 200
      rotated = Jason.decode!(conn.resp_body)

      assert rotated["refresh_token"] != tokens["refresh_token"]
      assert rotated["access_token"] != tokens["access_token"]
      assert is_binary(OAuth.open_session(rotated["access_token"]))

      # 滚动窗口：轮换把新行的 expires_at 前推（连续使用不断，闲置才过期）
      rows =
        OAuthRefreshToken
        |> Ash.Query.filter(user_id == ^user.id and client_id == ^tokens["client_id"])
        |> Ash.read!(authorize?: false)

      assert [older, newer] = Enum.sort_by(rows, & &1.generation)
      assert older.generation == 0
      assert newer.generation == 1
      assert newer.chain_id == older.chain_id
      assert older.rotated_to_id == newer.id
      assert DateTime.compare(newer.expires_at, older.expires_at) == :gt

      # 旧 refresh 再用 → invalid_grant（U2：宿主以此判定需重新授权）
      reuse = OAuth.refresh_token_request(tokens["refresh_token"], tokens["client_id"])
      assert reuse.status == 400
      assert Jason.decode!(reuse.resp_body)["error"] == "invalid_grant"

      # 重用检测级联整链：轮换后的 refresh 也已失效
      after_reuse = OAuth.refresh_token_request(rotated["refresh_token"], tokens["client_id"])
      assert after_reuse.status == 400
      assert Jason.decode!(after_reuse.resp_body)["error"] == "invalid_grant"
    end

    test "错误 PKCE verifier / 错误 redirect_uri / 无效码一律 invalid_grant" do
      user = Fixtures.register_user("oauth-grant-errors")
      tokens = OAuth.authorize!(user)

      {code, _verifier} = OAuth.code_for(user, tokens["client_id"], tokens["redirect_uri"])

      bad_verifier =
        OAuth.exchange_code(
          code,
          OAuth.pkce_verifier(),
          tokens["redirect_uri"],
          tokens["client_id"]
        )

      assert bad_verifier.status == 400
      assert Jason.decode!(bad_verifier.resp_body)["error"] == "invalid_grant"

      {code2, verifier2} = OAuth.code_for(user, tokens["client_id"], tokens["redirect_uri"])

      bad_redirect =
        OAuth.exchange_code(code2, verifier2, "http://127.0.0.1:1/cb", tokens["client_id"])

      assert bad_redirect.status == 400
      assert Jason.decode!(bad_redirect.resp_body)["error"] == "invalid_grant"

      unknown_code =
        OAuth.exchange_code(
          "0199e5a2-7c3f-7a41-9b0e-000000000000",
          verifier2,
          tokens["redirect_uri"],
          tokens["client_id"]
        )

      assert unknown_code.status == 400
      assert Jason.decode!(unknown_code.resp_body)["error"] == "invalid_grant"
    end

    test "已消费的授权码二次使用被拒" do
      user = Fixtures.register_user("oauth-code-reuse")
      tokens = OAuth.authorize!(user)
      {code, verifier} = OAuth.code_for(user, tokens["client_id"], tokens["redirect_uri"])

      first =
        OAuth.exchange_code(code, verifier, tokens["redirect_uri"], tokens["client_id"])

      assert first.status == 200

      conn = OAuth.exchange_code(code, verifier, tokens["redirect_uri"], tokens["client_id"])
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_grant"
    end

    test "用户在授权页拒绝 → 302 回带 access_denied（error_description 直达用户）" do
      user = Fixtures.register_user("oauth-deny")
      client_id = OAuth.dcr_client([@loopback_redirect])

      consent_conn =
        user.email
        |> OAuth.sign_in_cookie()
        |> OAuth.consent_get(client_id, @loopback_redirect, OAuth.pkce_verifier())

      assert consent_conn.status == 200

      params = consent_conn |> OAuth.consent_post("deny") |> OAuth.callback_params()

      assert params["error"] == "access_denied"
      assert params["iss"] == OAuth.issuer_url()
      # 未落同意记录：下次授权仍会展示授权页
      assert Ash.count!(OAuthConsent, authorize?: false) == 0
    end

    test "未登录访问授权页 → 401（授权页体验与登录引导由 U4 接手）" do
      client_id = OAuth.dcr_client([@loopback_redirect])

      conn = OAuth.consent_get(nil, client_id, @loopback_redirect, OAuth.pkce_verifier())

      assert conn.status == 401
    end

    test "已同意（scope 覆盖）时直接发码，不再展示授权页" do
      user = Fixtures.register_user("oauth-consent-reuse")
      tokens = OAuth.authorize!(user)

      conn =
        user.email
        |> OAuth.sign_in_cookie()
        |> OAuth.consent_get(
          tokens["client_id"],
          @loopback_redirect,
          OAuth.pkce_verifier()
        )

      assert OAuth.callback_params(conn)["code"]
    end
  end

  # ---- 打包路径 ----

  describe "打包路径（预注册公开 client）" do
    test "固定 client_id 完成完整授权（不经过注册端点）" do
      {client_id, redirect_uri} = OAuth.packaged_client!()
      assert client_id == OAuthClient.packaged_client_id()

      user = Fixtures.register_user("oauth-packaged")

      tokens =
        OAuth.authorize!(user, client_id: client_id, redirect_uri: redirect_uri)

      assert is_binary(tokens["access_token"])
      assert is_binary(tokens["refresh_token"])
      assert is_binary(OAuth.open_session(tokens["access_token"]))
    end

    test "幂等：重复 ensure 复用同一行" do
      {:ok, first} = OAuthClient.ensure_packaged_client()
      {:ok, second} = OAuthClient.ensure_packaged_client()

      assert first.id == second.id
      assert Ash.count!(OAuthClient, authorize?: false) == 1
    end
  end

  # ---- 撤销 ----

  describe "撤销（级联 refresh，下一次调用即 401）" do
    test "RFC 7009 /oauth/revoke 后同授权全部令牌失效且响应 200" do
      user = Fixtures.register_user("oauth-revoke-endpoint")
      tokens = OAuth.authorize!(user)

      assert is_binary(OAuth.open_session(tokens["access_token"]))

      conn =
        build_conn()
        |> post("/oauth/revoke", %{
          "token" => tokens["refresh_token"],
          "client_id" => tokens["client_id"],
          "token_type_hint" => "refresh_token"
        })

      assert conn.status == 200

      # 活跃性回查：撤销后下一次调用即 401（不依赖 access token 自然过期）
      denied = OAuth.post_mcp(tokens["access_token"], OAuth.initialize_body())
      assert denied.status == 401
      assert get_resp_header(denied, "www-authenticate") != []

      # 刷新同样被拒，错误码 invalid_grant（宿主据此触发重新授权）
      refresh = OAuth.refresh_token_request(tokens["refresh_token"], tokens["client_id"])
      assert refresh.status == 400
      assert Jason.decode!(refresh.resp_body)["error"] == "invalid_grant"
    end

    test "web 撤销面（revoke_authorization/2）同样即时失效" do
      user = Fixtures.register_user("oauth-revoke-web")
      tokens = OAuth.authorize!(user)

      assert :ok = OAuthRefreshToken.revoke_authorization(user.id, tokens["client_id"])

      assert OAuth.post_mcp(tokens["access_token"], OAuth.initialize_body()).status == 401
    end

    test "闲置超过窗口（expires_at 不再前推）的授权调用得到 401" do
      user = Fixtures.register_user("oauth-idle")
      tokens = OAuth.authorize!(user)

      OAuth.expire_authorization!(tokens)

      assert OAuth.post_mcp(tokens["access_token"], OAuth.initialize_body()).status == 401

      refresh = OAuth.refresh_token_request(tokens["refresh_token"], tokens["client_id"])
      assert refresh.status == 400
      assert Jason.decode!(refresh.resp_body)["error"] == "invalid_grant"
    end

    test "撤销只作用于目标授权：另一 client 的授权不受影响" do
      user = Fixtures.register_user("oauth-revoke-scope")
      first = OAuth.authorize!(user)
      second = OAuth.authorize!(user)

      assert :ok = OAuthRefreshToken.revoke_authorization(user.id, first["client_id"])

      assert OAuth.post_mcp(first["access_token"], OAuth.initialize_body()).status == 401
      assert OAuth.post_mcp(second["access_token"], OAuth.initialize_body()).status == 200
    end
  end

  # ---- 归因 ----

  describe "凭证类型归因（KTD8）" do
    test "静态连接 token 的调用落 :token，OAuth 的落 :oauth" do
      user = Fixtures.register_user("oauth-attribution")

      {:ok, _token, plain} = Token.issue("attribution test", user)
      session_id = OAuth.open_session(plain)

      OAuth.call_tool(plain, session_id, "list_my_workspaces", %{})
      assert last_log!("list_my_workspaces").credential_type == :token

      oauth = OAuth.authorize!(user)
      oauth_session = OAuth.open_session(oauth["access_token"])
      OAuth.call_tool(oauth["access_token"], oauth_session, "list_my_workspaces", %{})

      log = last_log!("list_my_workspaces")
      assert log.credential_type == :oauth
      assert log.user_id == user.id
    end
  end
end
