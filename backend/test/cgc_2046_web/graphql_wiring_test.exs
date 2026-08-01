defmodule Cgc2046Web.GraphqlWiringTest do
  use Cgc2046Web.ConnCase, async: true

  test "GraphQL endpoint answers a query through the AshGraphQL pipeline", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => "query { ping }"})

    assert %{"data" => %{"ping" => "pong"}} = json_response(conn, 200)
  end

  test "GraphQL playground is served at /api/playground", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/api/playground")

    assert html_response(conn, 200) =~ ~r/GraphiQL/i
  end
end
