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

  # 防回归：middleware/3 callback 的 pattern 必须把 RateLimit 挂到这两个 field。
  # validate_invitation 是 query、accept_invitation 是 mutation，分别从对应类型取。
  # 端到端限流测试（graphql_invitation_rate_limit_test.exs）测的是 plug 运行时行为，
  # 这里测的是 schema 接线——identifier 改名或 callback 被删时，这里会精确失败。
  # 纯 schema 内省，不依赖 DB / conn / 限流计数。
  describe "RateLimit middleware wiring" do
    test "validate_invitation (query) and accept_invitation (mutation) mount RateLimit" do
      schema = Cgc2046Web.GraphqlSchema
      query_type = Absinthe.Schema.lookup_type(schema, :query)
      mutation_type = Absinthe.Schema.lookup_type(schema, :mutation)

      for {name, type} <- [
            {:validate_invitation, query_type},
            {:accept_invitation, mutation_type}
          ] do
        field = type.fields[name]
        assert field != nil, "#{name} field missing from #{type.identifier} type"

        assert Enum.any?(field.middleware, fn
                 {Cgc2046Web.Plugs.RateLimit, _} -> true
                 _ -> false
               end),
               "#{name} middleware list missing RateLimit: #{inspect(field.middleware)}"
      end
    end
  end
end
