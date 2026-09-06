defmodule Cgc2046Web.GraphqlPlatformAuditTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures

  defp token(email) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{
        "query" =>
          "mutation { signIn(login: \"#{email}\", password: \"#{Fixtures.password()}\") { id } }"
      })

    conn.resp_cookies["cgc_token"].value
  end

  test "platform admin receives redacted workflow metadata only" do
    admin = Fixtures.platform_admin("audit-redacted")

    query = """
    query {
      platformWorkflowAudit {
        id workspaceId definitionType status startedAt finishedAt insertedAt
      }
    }
    """

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token(admin.email)}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})
      |> json_response(200)

    assert %{"data" => %{"platformWorkflowAudit" => rows}} = response
    assert is_list(rows)
    assert Enum.all?(rows, &(!Map.has_key?(&1, "facts")))
  end
end
