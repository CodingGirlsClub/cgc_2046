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
    assert Map.has_key?(body["data"], "myLearningRuns")

    {body, _} = graphql_post(conn, "mutation { revokeToken }", token)
    assert %{"data" => %{"revokeToken" => true}} = body

    {body, _} = graphql_post(conn, @learning_runs_query, token)
    assert body["data"] == nil or body["data"]["myLearningRuns"] == nil
    assert body["errors"] != nil and body["errors"] != []
  end

  test "revokeToken without a Bearer token is rejected", %{conn: conn} do
    {body, _} = graphql_post(conn, "mutation { revokeToken }")
    assert [%{"code" => "authentication_failed"} | _] = body["errors"]
  end

  test "invalid password returns the unified auth failure and no token", %{conn: conn} do
    user = Fixtures.register_user("desktop-badpw")
    {body, _} = sign_in_for_desktop(conn, to_string(user.email), "not-the-password")

    assert [%{"code" => "authentication_failed"} | _] = body["errors"]
    assert body["data"]["signInForDesktop"] == nil
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
