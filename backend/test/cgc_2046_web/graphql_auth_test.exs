defmodule Cgc2046Web.GraphqlAuthTest do
  use Cgc2046Web.ConnCase, async: true

  @email "graphql@example.com"
  @password "sup3r-secret-password"

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
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
