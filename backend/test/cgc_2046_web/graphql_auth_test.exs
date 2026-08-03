defmodule Cgc2046Web.GraphqlAuthTest do
  use Cgc2046Web.ConnCase, async: true

  @email "graphql@example.com"
  @password "sup3r-secret-password"

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp graphql_response(conn) do
    json_response(conn, 200)
  end

  # ponytail: 复用 graphql_profile_test.exs:72 的正向范式——读 conn.resp_cookies，
  # 断言 before_send 写入了 httpOnly cgc_token。这是 GAP1 的正向 regression guard：
  # 误删 router 的 before_send 注册或改错 cookie 选项时此断言会失败。
  defp assert_auth_cookie_written(conn) do
    cookie = conn.resp_cookies["cgc_token"]
    assert cookie != nil, "expected cgc_token cookie to be written by before_send"
    assert cookie.http_only == true, "cgc_token must be httpOnly (防 JS 读取)"
    assert cookie.same_site == "Lax", "cgc_token sameSite 应为 Lax"
    assert is_binary(cookie.value) and byte_size(cookie.value) > 0, "cgc_token 值非空"
    cookie
  end

  defp sign_up_query(email, password) do
    """
    mutation {
      signUp(input: { email: "#{email}", password: "#{password}" }) {
        result { id email isPlatformAdmin }
        errors { message }
      }
    }
    """
  end

  describe "signUp mutation" do
    test "registers a user and returns the user (token in httpOnly cookie)" do
      conn = build_conn()

      res = graphql_post(conn, sign_up_query(@email, @password))

      assert %{"data" => %{"signUp" => %{"result" => result}}} = res
      assert result["email"] == @email
      assert result["isPlatformAdmin"] == false
      # token 由后端 before_send 写 httpOnly cookie，响应体不返回
      refute Map.has_key?(res["data"]["signUp"], "metadata")
    end

    test "returns a validation error for a duplicate email" do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password))

      res = graphql_post(conn, sign_up_query(@email, @password))

      assert %{"data" => %{"signUp" => %{"errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "already been taken"))
    end

    test "rejects an invalid email format" do
      conn = build_conn()

      res = graphql_post(conn, sign_up_query("not-an-email", @password))

      assert %{"data" => %{"signUp" => %{"result" => result, "errors" => errors}}} = res
      assert is_nil(result)
      assert Enum.any?(errors, &(&1["message"] =~ "email"))
    end
  end

  describe "signIn mutation" do
    setup do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password))

      {:ok, conn: conn}
    end

    test "signs in with correct credentials and returns the user (token in httpOnly cookie)" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "#{@password}") {
          id
          email
          isPlatformAdmin
        }
      }
      """

      res = graphql_post(build_conn(), query)

      assert %{"data" => %{"signIn" => sign_in}} = res
      assert sign_in["email"] == @email
      assert sign_in["isPlatformAdmin"] == false
      # token 由后端 before_send 写 httpOnly cookie，响应体不返回
      refute Map.has_key?(sign_in, "token")
    end

    test "returns an error for an invalid password" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "wrong-password") {
          id
          email
        }
      }
      """

      res = graphql_post(build_conn(), query)

      assert %{"data" => %{"signIn" => nil}, "errors" => errors} = res

      assert [%{"message" => "Invalid email or password", "code" => "authentication_failed"}] =
               errors
    end
  end
end
