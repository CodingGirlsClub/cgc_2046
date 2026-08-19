defmodule Cgc2046Web.GraphqlMcpTokenTest do
  @moduledoc """
  切片 D Phase 2（#44 提前）：MCP 连接 token 的 GraphQL 契约测试。

  三个手写入口（不走 AshGraphql 自动生成，D-D4/D-D10）：
  - `myMcpTokens`：当前用户 token 列表（不含明文，新→旧）
  - `createMcpToken(name:)`：签发；明文仅经 `plainToken` 一次性返回
  - `revokeMcpToken(id:)`：撤销（置 revoked_at，保留审计行）
  """
  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.User
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token, as: McpToken

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

  defp sign_in_token(email, password) do
    query = """
    mutation {
      signIn(login: "#{email}", password: "#{password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp create_mcp_token_mutation(name) do
    """
    mutation {
      createMcpToken(name: #{inspect(name)}) {
        result { id name lastUsedAt revokedAt insertedAt }
        plainToken
        errors { message code }
      }
    }
    """
  end

  defp issue_token(auth_token, name) do
    res = graphql_post(build_conn(), create_mcp_token_mutation(name), auth_token)

    assert %{
             "data" => %{
               "createMcpToken" => %{
                 "result" => %{"id" => _} = result,
                 "plainToken" => plain,
                 "errors" => []
               }
             }
           } = res

    {result, plain}
  end

  describe "myMcpTokens" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), "query { myMcpTokens { id } }")
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "returns own tokens newest first, excluding other users'" do
      user = Fixtures.register_user("gql-mcp-token-user")
      other = Fixtures.register_user("gql-mcp-token-other")
      auth = sign_in_token(user.email, @password)
      other_auth = sign_in_token(other.email, @password)

      {_t1, _} = issue_token(auth, "first")
      {_t2, _} = issue_token(auth, "second")
      {_other, _} = issue_token(other_auth, "not-mine")

      res =
        graphql_post(
          build_conn(),
          "query { myMcpTokens { id name revokedAt insertedAt } }",
          auth
        )

      assert %{"data" => %{"myMcpTokens" => tokens}} = res
      assert Enum.map(tokens, & &1["name"]) == ["second", "first"]
      assert Enum.all?(tokens, &(&1["revokedAt"] == nil))
    end

    test "token type does not expose plainToken (明文不可经 query 读回)" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)

      res = graphql_post(build_conn(), "query { myMcpTokens { id plainToken } }", auth)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "plainToken"))
    end
  end

  describe "createMcpToken" do
    test "anonymous is unauthorized" do
      res = graphql_post(build_conn(), create_mcp_token_mutation("laptop"))
      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "issues token: plaintext returned once, only SHA256 hash persisted" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)

      {result, plain} = issue_token(auth, "my-laptop")

      assert result["name"] == "my-laptop"
      assert result["revokedAt"] == nil
      assert result["insertedAt"]
      assert String.starts_with?(plain, "cgc_")

      # 库中只存 hash：按明文 sha256 能查到行，且任何字段不含明文
      hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

      stored =
        McpToken
        |> Ash.Query.filter(token_hash == ^hash)
        |> Ash.read_one!(authorize?: false)

      assert stored.name == "my-laptop"
      refute inspect(Map.from_struct(stored)) =~ plain

      # 签发的 token 立即可用于 MCP 鉴权前置校验
      assert {:ok, %User{id: id}} = McpToken.validate_token(plain)
      assert id == user.id
    end

    test "blank name returns structured errors, no token created" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)

      res = graphql_post(build_conn(), create_mcp_token_mutation(""), auth)

      assert %{
               "data" => %{
                 "createMcpToken" => %{
                   "result" => nil,
                   "plainToken" => nil,
                   "errors" => [error | _]
                 }
               }
             } = res

      # Ash 将 "" cast 为 nil → allow_nil?: false → Required 错误
      assert error["code"] == "required"
    end
  end

  describe "revokeMcpToken" do
    test "anonymous is unauthorized" do
      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeMcpToken(id: "#{Ecto.UUID.generate()}") { id } }|
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] =~ "unauthorized"))
    end

    test "revokes own token: revokedAt set and token stops validating" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)
      {%{"id" => id}, plain} = issue_token(auth, "to-revoke")

      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeMcpToken(id: "#{id}") { id name revokedAt } }|,
          auth
        )

      assert %{"data" => %{"revokeMcpToken" => %{"id" => ^id, "revokedAt" => revoked_at}}} =
               res

      assert revoked_at

      # 撤销后 MCP 鉴权前置校验失败（审计行保留）
      assert :error = McpToken.validate_token(plain)

      hash = :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)

      assert McpToken
             |> Ash.Query.filter(token_hash == ^hash)
             |> Ash.read_one!(authorize?: false)
    end

    test "revoking another user's token returns not_found (不泄露存在性)" do
      user = Fixtures.register_user("gql-mcp-token-user")
      other = Fixtures.register_user("gql-mcp-token-other")
      auth = sign_in_token(user.email, @password)
      other_auth = sign_in_token(other.email, @password)
      {%{"id" => other_id}, _} = issue_token(other_auth, "other-token")

      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeMcpToken(id: "#{other_id}") { id } }|,
          auth
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "not_found"))
    end

    test "revoking unknown id returns not_found" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)

      res =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeMcpToken(id: "#{Ecto.UUID.generate()}") { id } }|,
          auth
        )

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "not_found"))
    end

    test "revoking an already revoked token returns invalid_attribute" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)
      {%{"id" => id}, _} = issue_token(auth, "double-revoke")

      mutation = ~s|mutation { revokeMcpToken(id: "#{id}") { id revokedAt } }|

      assert %{"data" => %{"revokeMcpToken" => %{"revokedAt" => _}}} =
               graphql_post(build_conn(), mutation, auth)

      res = graphql_post(build_conn(), mutation, auth)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "invalid_attribute"))
      assert Enum.any?(errors, &(&1["message"] =~ "already been revoked"))
    end
  end

  describe "revokeMcpToken error structure contract" do
    # advisor02 SUGGESTED：revoke 各错误分支的 GraphQL error 对象字段结构应与
    # AshGraphql 原行为（to_ash_graphql_errors 输出）一致——message/code/fields
    # 齐备，未来客户端可依赖统一错误形状分流。
    test "not_found (other user / unknown id) exposes message/code/fields like AshGraphql" do
      user = Fixtures.register_user("gql-mcp-token-user")
      other = Fixtures.register_user("gql-mcp-token-other")
      auth = sign_in_token(user.email, @password)
      other_auth = sign_in_token(other.email, @password)
      {%{"id" => other_id}, _} = issue_token(other_auth, "other-token")

      for id <- [other_id, Ecto.UUID.generate()] do
        res =
          graphql_post(
            build_conn(),
            ~s|mutation { revokeMcpToken(id: "#{id}") { id } }|,
            auth
          )

        assert %{"errors" => [error]} = res
        assert error["code"] == "not_found"
        # AshGraphql NotFound.to_error 的 message
        assert error["message"] == "could not be found"
        # NotFound.to_error: fields = Map.keys(primary_key || %{})，Ash.get 失败时
        # primary_key = %{id: id} → fields = ["id"]（探针实测）
        assert error["fields"] == ["id"]
      end
    end

    test "invalid (already revoked) exposes message/code/fields like AshGraphql" do
      user = Fixtures.register_user("gql-mcp-token-user")
      auth = sign_in_token(user.email, @password)
      {%{"id" => id}, _} = issue_token(auth, "double-revoke")

      mutation = ~s|mutation { revokeMcpToken(id: "#{id}") { id revokedAt } }|

      assert %{"data" => %{"revokeMcpToken" => %{"revokedAt" => _}}} =
               graphql_post(build_conn(), mutation, auth)

      res = graphql_post(build_conn(), mutation, auth)

      assert %{"errors" => [error]} = res
      assert error["code"] == "invalid_attribute"
      assert error["message"] == "Token has already been revoked"
      assert error["fields"] == ["revoked_at"]
    end

    test "all revoke error branches share the same error entry field keys" do
      user = Fixtures.register_user("gql-mcp-token-user")
      other = Fixtures.register_user("gql-mcp-token-other")
      auth = sign_in_token(user.email, @password)
      other_auth = sign_in_token(other.email, @password)
      {%{"id" => other_id}, _} = issue_token(other_auth, "other-token")
      {%{"id" => own_id}, _} = issue_token(auth, "own-token")

      mutation = ~s|mutation { revokeMcpToken(id: "#{own_id}") { id revokedAt } }|

      assert %{"data" => %{"revokeMcpToken" => %{"revokedAt" => _}}} =
               graphql_post(build_conn(), mutation, auth)

      [nf_error] =
        graphql_post(
          build_conn(),
          ~s|mutation { revokeMcpToken(id: "#{other_id}") { id } }|,
          auth
        )["errors"]

      [inv_error] = graphql_post(build_conn(), mutation, auth)["errors"]

      # Absinthe 自动附加 locations/path；契约要求 message/code/fields 三键各分支齐备
      assert MapSet.subset?(
               MapSet.new(["message", "code", "fields"]),
               MapSet.new(Map.keys(nf_error))
             )

      assert MapSet.new(Map.keys(nf_error)) == MapSet.new(Map.keys(inv_error))
    end
  end
end
