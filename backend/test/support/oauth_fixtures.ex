defmodule Cgc2046.OAuthFixtures do
  @moduledoc """
  OAuth 授权布置的唯一入口（U3）：经**真路由**完成协议流程，不 mock 授权服务器。

  与 `AccountsFixtures` 同定位（布置而非被测对象）：

  - `authorize!/2`：DCR（或给定 client_id）→ 授权页同意 → 码换令牌，返回
    `%{"access_token" =>, "refresh_token" =>, "client_id" =>, "redirect_uri" =>, "user" =>}`
  - `sign_in_cookie/1`：经 `/api/graphql` signIn 拿 `cgc_token`（授权页读该
    host-only 登录 cookie；见 KTD2）
  - `expire_authorization!/1`：把一条授权的当前行推到过期，构造「闲置超过窗口」
    的真实状态（`expires_at` 无写动作，故这里用 SQL 布置，测试专用）
  - `/mcp` 侧：`post_mcp/3` / `open_session/1` / `call_tool/4`
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  # Phoenix.ConnTest.dispatch/3 读调用方模块的 @endpoint（ConnCase 里设在测试模块上）。
  @endpoint Cgc2046Web.Endpoint

  alias Cgc2046.Accounts.{OAuthClient, OAuthRefreshToken}
  alias Cgc2046.AccountsFixtures
  alias Cgc2046.Oauth2Server

  require Ash.Query

  @default_redirect "http://127.0.0.1:19876/mcp/oauth/callback"
  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"oauth-fixture","version":"0.0.0"}}})

  def default_redirect_uri, do: @default_redirect
  def issuer_url, do: Oauth2Server.issuer_url()
  def resource_url, do: Oauth2Server.resource_url()

  # ---- 协议端点 ----

  def register_client(redirect_uris, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "client_name" => "opencode",
          "redirect_uris" => redirect_uris,
          "grant_types" => ["authorization_code", "refresh_token"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none"
        },
        extra
      )

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/oauth/register", Jason.encode!(body))

    {conn, Jason.decode!(conn.resp_body)}
  end

  def dcr_client(redirect_uris) do
    {conn, body} = register_client(redirect_uris)
    assert conn.status == 201
    body["client_id"]
  end

  def sign_in_cookie(user_email) do
    query = """
    mutation {
      signIn(login: "#{user_email}", password: "#{AccountsFixtures.password()}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  def pkce_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  def pkce_challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  def consent_get(cookie, client_id, redirect_uri, verifier, req_headers \\ []) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" => Oauth2Server.scope(),
        "state" => "state-#{System.unique_integer([:positive])}",
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256",
        "resource" => resource_url()
      })

    conn = build_conn()
    conn = if cookie, do: put_req_cookie(conn, "cgc_token", cookie), else: conn

    # req_headers: [{"accept-language", "en"}, …]（二进制名值对，直接进请求头）
    conn = Enum.reduce(req_headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    get(conn, "/oauth/authorize?" <> query)
  end

  def consent_post(conn, action) do
    conn
    |> recycle()
    |> post("/oauth/authorize", %{
      "action" => action,
      "consent_request" => hidden_field(conn.resp_body, "consent_request"),
      "_csrf_token" => hidden_field(conn.resp_body, "_csrf_token")
    })
  end

  def callback_params(conn) do
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    URI.decode_query(URI.parse(location).query)
  end

  # 取一个新码：首次访问渲染授权页并同意；已同意时库直接 302 发码。
  # 返回 `{code, verifier}`（verifier 与该码的 PKCE challenge 配对）。
  def code_for(user, client_id, redirect_uri) do
    verifier = pkce_verifier()

    conn =
      user.email
      |> sign_in_cookie()
      |> consent_get(client_id, redirect_uri, verifier)

    case conn.status do
      302 ->
        {callback_params(conn)["code"], verifier}

      200 ->
        # 未同意 → 渲染同意页（断言表单要素而非按钮文案：文案是 U4 视图 + gettext 的事）
        assert conn.resp_body =~ ~s(name="consent_request" value=")
        %{"code" => code} = conn |> consent_post("approve") |> callback_params()
        {code, verifier}
    end
  end

  def exchange_code(code, verifier, redirect_uri, client_id, grant_extra \\ %{}) do
    params =
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "code_verifier" => verifier,
          "redirect_uri" => redirect_uri,
          "client_id" => client_id,
          "resource" => resource_url()
        },
        grant_extra
      )

    build_conn() |> post("/oauth/token", params)
  end

  def refresh_token_request(refresh, client_id) do
    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh,
      "client_id" => client_id,
      "resource" => resource_url()
    })
  end

  @doc "完整授权（DCR 或给定 client_id）。返回令牌与归属信息。"
  def authorize!(user, opts \\ []) do
    client_id = Keyword.get_lazy(opts, :client_id, fn -> dcr_client([@default_redirect]) end)
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect)

    {code, verifier} = code_for(user, client_id, redirect_uri)

    conn = exchange_code(code, verifier, redirect_uri, client_id)
    assert conn.status == 200

    conn.resp_body
    |> Jason.decode!()
    |> Map.merge(%{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "user" => user
    })
  end

  @doc """
  把一条授权的当前行推到过期（构造「连续闲置超过窗口」状态）。

  `expires_at` 没有写动作（真实滚动窗口由轮换前推），故测试用 SQL 布置该状态。
  """
  def expire_authorization!(tokens) do
    row =
      OAuthRefreshToken
      |> Ash.Query.filter(
        user_id == ^tokens["user"].id and client_id == ^tokens["client_id"] and
          is_nil(rotated_to_id)
      )
      |> Ash.read_one!(authorize?: false)

    Cgc2046.Repo.query!(
      "UPDATE oauth_refresh_tokens SET expires_at = $1 WHERE id = $2",
      [DateTime.add(DateTime.utc_now(), -1, :day), Ecto.UUID.dump!(row.id)]
    )
  end

  @doc "预注册打包 client 的双凭证布置：返回 {client_id, redirect_uri}。"
  def packaged_client! do
    {:ok, client} = OAuthClient.ensure_packaged_client()
    {client.id, hd(OAuthClient.packaged_redirect_uris())}
  end

  # ---- /mcp ----

  def initialize_body, do: @initialize_body

  def post_mcp(token, body, session_id \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn

    post(conn, "/mcp", body)
  end

  def open_session(token) do
    conn = post_mcp(token, @initialize_body)

    if conn.status == 200 do
      [session_id] = get_resp_header(conn, "mcp-session-id")
      session_id
    end
  end

  def call_tool(token, session_id, name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    conn = post_mcp(token, body, session_id)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  @doc "从同意页 HTML 取隐藏域值（`name=\"…\" value=\"…\"` 是库 ConsentRouter 的渲染约定）。"
  def hidden_field(html, name) do
    [_, value] = Regex.run(~r/name="#{name}" value="([^"]*)"/, html)
    value
  end
end
