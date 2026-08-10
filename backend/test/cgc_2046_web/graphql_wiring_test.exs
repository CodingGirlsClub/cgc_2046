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

  # 防回归：validate_invitation 是 AshGraphql 自动生成的 query field，其 RateLimit 由
  # middleware/3 callback 挂载，静态 field.middleware 列表可见——identifier 改名或
  # callback 被删时，这里会精确失败。
  # accept_invitation 现为手写 resolver field（#96 绕过 read policy 记录加载），
  # 其 RateLimit 经 middleware/2 宏声明。手写 field（resolve(fn) 形式）的 middleware
  # 被 Absinthe shim 包装，不进静态 field.middleware 列表（与 sign_in /
  # admit_member_by_token 一致），故其限流由 graphql_invitation_rate_limit_test.exs
  # 端到端运行时验证，不在此静态内省。
  # 纯 schema 内省，不依赖 DB / conn / 限流计数。
  describe "RateLimit middleware wiring" do
    test "validate_invitation (auto query) mounts RateLimit via middleware/3 callback" do
      schema = Cgc2046Web.GraphqlSchema
      query_type = Absinthe.Schema.lookup_type(schema, :query)

      field = query_type.fields[:validate_invitation]
      assert field != nil, "validate_invitation field missing from query type"

      assert Enum.any?(field.middleware, fn
               {Cgc2046Web.Plugs.RateLimit, _} -> true
               _ -> false
             end),
             "validate_invitation middleware list missing RateLimit: #{inspect(field.middleware)}"
    end
  end
end
