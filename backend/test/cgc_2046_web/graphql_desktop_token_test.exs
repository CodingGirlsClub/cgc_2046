defmodule Cgc2046Web.GraphqlDesktopTokenTest do
  @moduledoc """
  Story 2.13：第一方客户端（桌面）Bearer token 的签发与撤销。

  契约：
  - `signInForDesktop` 复用 AshAuthentication JWT，经**响应体**交付 token，不写 httpOnly cookie；
  - 该 token 作为 `Authorization: Bearer` 可访问受保护查询；
  - `revokeToken` 只撤销当前 Bearer token，撤销后同一 token 立即失效（401/未授权）；
  - web 的 `signIn` cookie 交付路径保持不变（回归）。
  """
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures

  @password Fixtures.password()
  @learning_runs_query "{ myLearningRuns { runId status } }"

  defp graphql_post(conn, query, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    {json_response(conn, 200), conn}
  end

  defp sign_in_for_desktop(conn, login, password \\ @password) do
    query = """
    mutation {
      signInForDesktop(login: #{inspect(login)}, password: #{inspect(password)}) {
        token
        userId
        email
        isPlatformAdmin
      }
    }
    """

    graphql_post(conn, query)
  end

  defp sign_in_web(conn, login, password \\ @password) do
    query = """
    mutation {
      signIn(login: #{inspect(login)}, password: #{inspect(password)}) {
        id
      }
    }
    """

    graphql_post(conn, query)
  end

  test "desktop sign-in returns a Bearer JWT in the body and never sets the auth cookie", %{
    conn: conn
  } do
    user = Fixtures.register_user("desktop-token")

    {body, resp_conn} = sign_in_for_desktop(conn, to_string(user.email))
    assert %{"data" => %{"signInForDesktop" => result}} = body
    token = result["token"]

    assert is_binary(token)
    assert length(String.split(token, ".")) == 3, "expected a three-segment JWT"
    assert result["userId"] == user.id
    assert result["email"] == to_string(user.email)
    assert is_boolean(result["isPlatformAdmin"])

    # 桌面 token 不在响应里写 cookie：客户端自己存 Bearer，不复用浏览器会话
    refute resp_conn.resp_cookies["cgc_token"]

    # Bearer 可访问受保护查询
    {body, _} = graphql_post(conn, @learning_runs_query, token)
    assert %{"data" => %{"myLearningRuns" => runs}} = body
    assert is_list(runs)
  end

  test "revokeToken revokes the calling token; the same token is rejected afterwards", %{
    conn: conn
  } do
    user = Fixtures.register_user("desktop-revoke")
    {body, _} = sign_in_for_desktop(conn, to_string(user.email))
    token = body["data"]["signInForDesktop"]["token"]

    {body, _} = graphql_post(conn, @learning_runs_query, token)
    assert is_list(body["data"]["myLearningRuns"]), "token must work before revoke"

    {body, _} = graphql_post(conn, "mutation { revokeToken }", token)
    assert %{"data" => %{"revokeToken" => true}} = body

    {body, _} = graphql_post(conn, @learning_runs_query, token)
    assert [%{"code" => "unauthorized"} | _] = body["errors"]
  end

  test "revokeToken without a Bearer token is rejected", %{conn: conn} do
    {body, _} = graphql_post(conn, "mutation { revokeToken }")
    assert [%{"code" => "unauthorized"} | _] = body["errors"]
  end

  test "revokeToken rejects a forged bearer without writing the tokens table", %{conn: conn} do
    before = token_count()
    forged = forged_jwt("forged-jti-#{Ecto.UUID.generate()}")
    {body, _} = graphql_post(conn, "mutation { revokeToken }", forged)

    assert [%{"code" => "unauthorized"} | _] = body["errors"]
    assert token_count() == before, "forged Bearer must not create/overwrite a token row"
  end

  test "desktop token carries platform=desktop and survives web-face re-login revocation", %{
    conn: conn
  } do
    user = Fixtures.register_user("desktop-platform")
    {body, _} = sign_in_for_desktop(conn, to_string(user.email))
    token = body["data"]["signInForDesktop"]["token"]

    payload = jwt_payload(token)
    assert payload["platform"] == "desktop"
    assert is_integer(payload["exp"])

    # web 面重登吊销只针对 platform IS NULL OR = 'web' 的 token：桌面 token 必须存活
    assert :ok = Cgc2046.Accounts.SignInFlow.revoke_stored_tokens(user, :web)
    {body, _} = graphql_post(conn, @learning_runs_query, token)

    assert is_list(body["data"]["myLearningRuns"]),
           "desktop token must survive web-face revocation"
  end

  test "invalid password returns the unified auth failure and no token", %{conn: conn} do
    user = Fixtures.register_user("desktop-badpw")
    {body, _} = sign_in_for_desktop(conn, to_string(user.email), "not-the-password")

    assert [%{"code" => "authentication_failed"} | _] = body["errors"]
    assert body["data"]["signInForDesktop"] == nil
  end

  defp token_count do
    %{rows: [[count]]} = Cgc2046.Repo.query!("SELECT count(*) FROM tokens")
    count
  end

  defp forged_jwt(jti) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)

    payload =
      Base.url_encode64(
        Jason.encode!(%{
          "jti" => jti,
          "sub" => "forged",
          "exp" => 9_999_999_999,
          "purpose" => "user"
        }),
        padding: false
      )

    Enum.join([header, payload, "not-a-real-signature"], ".")
  end

  defp jwt_payload(token) do
    [_, payload, _] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "web signIn still delivers the httpOnly cookie (regression)", %{conn: conn} do
    user = Fixtures.register_user("web-cookie")
    {body, resp_conn} = sign_in_web(conn, to_string(user.email))
    assert %{"data" => %{"signIn" => %{"id" => _}}} = body

    cookie = resp_conn.resp_cookies["cgc_token"]
    assert cookie, "web signIn must keep delivering the auth cookie"
    assert cookie.http_only

    # cookie 里的 token 作为 Bearer 仍可用（服务端内部复用同一条验证路径）
    {body, _} = graphql_post(conn, @learning_runs_query, cookie.value)
    assert %{"data" => %{"myLearningRuns" => runs}} = body
    assert is_list(runs)
  end
end
