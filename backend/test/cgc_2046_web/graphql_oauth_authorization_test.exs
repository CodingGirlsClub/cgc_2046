defmodule Cgc2046Web.GraphqlOauthAuthorizationTest do
  @moduledoc """
  U5（KTD3）：我的 OAuth 授权 GraphQL 契约测试。

  两个手写入口（不走 AshGraphql 自动生成，读模型见 `Cgc2046.Accounts.OAuthAuthorizations`）：

  - `myOauthAuthorizations`：当前用户的授权列表（客户端名/授权时间/最近使用/状态）
  - `revokeOauthAuthorization(clientId:)`：撤销（整链 + 撤回同意行；仅本人）

  布置经 `Cgc2046.OAuthFixtures`（真路由完成协议流程）。

  async: false —— DCR 注册配额与失败节流用共享 ETS 表（同 OAuthFlowTest）。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.OAuthConsent
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.OAuthFixtures, as: OAuth

  require Ash.Query

  @password Fixtures.password()

  defp graphql_post(conn, query, token \\ nil) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(login: "#{email}", password: "#{@password}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  @list_query """
  query {
    myOauthAuthorizations {
      clientId
      clientName
      scope
      grantedAt
      lastUsedAt
      status
    }
  }
  """

  describe "myOauthAuthorizations" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), "query { myOauthAuthorizations { clientId } }")
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns own authorization with client name, scope, granted time and status" do
      user = Fixtures.register_user("gql-oauth-authz-user")
      auth = sign_in_token(user.email)
      tokens = OAuth.authorize!(user)

      res = graphql_post(build_conn(), @list_query, auth)

      assert %{"data" => %{"myOauthAuthorizations" => [row]}} = res
      assert row["clientId"] == tokens["client_id"]
      assert row["clientName"] == "opencode"
      assert row["scope"] == Cgc2046.Oauth2Server.scope()
      assert row["grantedAt"]
      assert row["lastUsedAt"] == nil
      assert row["status"] == "active"
    end

    test "one row per client and only the caller's own authorizations" do
      user = Fixtures.register_user("gql-oauth-authz-mine")
      other = Fixtures.register_user("gql-oauth-authz-other")
      auth = sign_in_token(user.email)
      mine = OAuth.authorize!(user)
      theirs = OAuth.authorize!(other)

      res = graphql_post(build_conn(), @list_query, auth)

      assert %{"data" => %{"myOauthAuthorizations" => rows}} = res
      assert Enum.map(rows, & &1["clientId"]) == [mine["client_id"]]
      refute Enum.any?(rows, &(&1["clientId"] == theirs["client_id"]))
    end
  end

  describe "revokeOauthAuthorization" do
    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeOauthAuthorization(clientId: "#{Ecto.UUID.generate()}") { clientId } }|
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "revokes own authorization: returns revoked status, kills the credential and withdraws consent" do
      user = Fixtures.register_user("gql-oauth-authz-revoke")
      auth = sign_in_token(user.email)
      tokens = OAuth.authorize!(user)

      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeOauthAuthorization(clientId: "#{tokens["client_id"]}") { clientId status } }|,
          auth
        )

      assert %{
               "data" => %{
                 "revokeOauthAuthorization" => %{
                   "clientId" => client_id,
                   "status" => "revoked"
                 }
               }
             } = res

      assert client_id == tokens["client_id"]

      # 宿主下一次调用即 401（活跃性回查，U3 响应语义）
      assert OAuth.post_mcp(tokens["access_token"], OAuth.initialize_body()).status == 401

      # 同意行撤回：重新授权回到同意页（不再静默发码）
      reconsent =
        OAuth.consent_get(
          OAuth.sign_in_cookie(user.email),
          tokens["client_id"],
          tokens["redirect_uri"],
          OAuth.pkce_verifier()
        )

      assert reconsent.status == 200

      # 审计行保留在列表里（链头已撤销）
      after_revoke = graphql_post(build_conn(), @list_query, auth)
      assert %{"data" => %{"myOauthAuthorizations" => [row]}} = after_revoke
      assert row["status"] == "revoked"
      assert row["grantedAt"] == nil

      assert OAuthConsent
             |> Ash.Query.filter(client_id == ^tokens["client_id"])
             |> Ash.read_one(authorize?: false) == {:ok, nil}
    end

    test "revoking another user's or unknown client id returns not_found (不泄露存在性)" do
      user = Fixtures.register_user("gql-oauth-authz-notfound")
      other = Fixtures.register_user("gql-oauth-authz-notfound-other")
      auth = sign_in_token(user.email)
      _mine = OAuth.authorize!(user)
      theirs = OAuth.authorize!(other)

      for client_id <- [theirs["client_id"], Ecto.UUID.generate()] do
        res =
          graphql_post(
            build_conn(),
            ~s|mutation { revokeOauthAuthorization(clientId: "#{client_id}") { clientId } }|,
            auth
          )

        assert %{"errors" => [error]} = res
        assert error["code"] == "not_found"
        assert error["message"] == "could not be found"

        # fields 取自 AshGraphql NotFound 的 primary_key 键（资源属性名，非 SDL 驼峰名）
        assert error["fields"] == ["client_id"]
      end

      # 他人授权不受影响
      assert OAuth.post_mcp(theirs["access_token"], OAuth.initialize_body()).status == 200
    end
  end
end
