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
        metadata { token }
      }
    }
    """
  end

  describe "signUp mutation" do
    test "registers a user and returns a JWT token in metadata" do
      conn = build_conn()

      res = graphql_post(conn, sign_up_query(@email, @password))

      assert %{"data" => %{"signUp" => %{"result" => result, "metadata" => metadata}}} = res
      assert result["email"] == @email
      assert result["isPlatformAdmin"] == false
      assert is_binary(metadata["token"])
      assert length(String.split(metadata["token"], ".")) == 3
    end

    test "returns a validation error for a duplicate email" do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password))

      res = graphql_post(conn, sign_up_query(@email, @password))

      assert %{"data" => %{"signUp" => %{"errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "already been taken"))
    end
  end

  describe "signIn mutation" do
    setup do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password))

      {:ok, conn: conn}
    end

    test "signs in with correct credentials and returns the user with token" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "#{@password}") {
          id
          email
          isPlatformAdmin
          token
        }
      }
      """

      res = graphql_post(build_conn(), query)

      assert %{"data" => %{"signIn" => sign_in}} = res
      assert sign_in["email"] == @email
      assert sign_in["isPlatformAdmin"] == false
      assert is_binary(sign_in["token"])
      assert length(String.split(sign_in["token"], ".")) == 3
    end

    test "returns an error for an invalid password" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "wrong-password") {
          id
          email
          token
        }
      }
      """

      res = graphql_post(build_conn(), query)

      assert %{"data" => %{"signIn" => nil}, "errors" => errors} = res
      assert [%{"message" => "Invalid email or password", "code" => "authentication_failed"}] = errors
    end
  end
end
