defmodule Cgc2046Web.GraphqlIntrospectionTest do
  use Cgc2046Web.ConnCase, async: true

  # VULN-001（#81）：introspection 仅 dev 开启（schema pipeline 按 dev_routes 移除
  # Introspection phase），test/prod 关闭——未认证者不可经 __schema/__type 枚举整个
  # schema，请求落标准 GraphQL validation error（Cannot query field）。
  # 本测试在 test env（dev_routes=false）下验证关闭行为，防止回归。

  test "test env: __schema introspection is disabled" do
    conn =
      build_conn()
      |> post("/api/graphql", %{"query" => "{ __schema { queryType { name } } }"})

    assert %{"errors" => errors} = json_response(conn, 200)
    assert Enum.any?(errors, fn e -> e["message"] == "Introspection is disabled" end)
  end

  test "test env: __type introspection is disabled" do
    conn =
      build_conn()
      |> post("/api/graphql", %{"query" => "{ __type(name: \"RootQueryType\") { name } }"})

    assert %{"errors" => errors} = json_response(conn, 200)
    assert Enum.any?(errors, fn e -> e["message"] == "Introspection is disabled" end)
  end

  test "ordinary query shape is unaffected" do
    conn =
      build_conn()
      |> post("/api/graphql", %{"query" => "{ __typename }"})

    assert %{"data" => %{"__typename" => "RootQueryType"}} = json_response(conn, 200)
  end
end
