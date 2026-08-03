defmodule Cgc2046Web.GraphqlWiringTest do
  use Cgc2046Web.ConnCase, async: true

  test "GraphQL endpoint answers a query through the AshGraphQL pipeline", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => "query { ping }"})

    assert %{"data" => %{"ping" => "pong"}} = json_response(conn, 200)
  end

  test "GraphQL playground is behind dev_routes guard (404 in test env)", %{conn: conn} do
    # Playground is gated behind Application.compile_env(:cgc_2046, :dev_routes),
    # which is true only in dev (config/dev.exs). In test and prod it is not set,
    # so the scope is not compiled -- return 404.
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/api/playground")

    assert response(conn, 404) =~ "Not Found"
  end
end
