defmodule Cgc2046Web.GraphqlComplexityTest do
  use Cgc2046Web.ConnCase, async: true

  # #297.1：GraphQL 查询成本限制（router @graphql_abuse_opts，非 dev 生效）。
  # test env（dev_routes=false）与 prod 同配置——本测试验证限制行为，防止回归。
  # 拒绝语义为 HTTP 200 + GraphQL errors（resolution 跳过、响应无 data 键），
  # 与 introspection guard 口径一致（标准 GraphQL 错误通道，非字面 4xx）。

  describe "max_complexity: 250" do
    test "超限别名炸弹被拒，错误含实际/上限值且不执行" do
      # 300 个 alias 化顶层标量字段（默认每 field complexity 1）→ 300 > 250
      bomb =
        "{ " <>
          Enum.map_join(0..299, " ", fn i -> "a#{i}: pendingApprovalsCount" end) <> " }"

      conn = build_conn() |> post("/api/graphql", %{"query" => bomb})
      body = json_response(conn, 200)

      assert %{"errors" => errors} = body
      refute Map.has_key?(body, "data"), "resolution 必须被跳过，响应不应含 data"

      assert Enum.any?(errors, fn e ->
               msg = e["message"] || ""

               String.contains?(msg, "complexity is 300") and
                 String.contains?(msg, "maximum is 250")
             end)
    end

    test "嵌套扇出同样被 complexity 上限拦截" do
      # 60 个 alias 化 list 字段 × (1 自身 + 5 子字段) = 360 > 250；
      # 字段取自真实 schema（myWorkspacePortfolio / portfolio_item），validation 通过。
      item = "id workspaceId title url icon"

      bomb =
        "{ " <>
          Enum.map_join(0..59, " ", fn i ->
            "a#{i}: myWorkspacePortfolio(workspaceId: \"00000000-0000-0000-0000-000000000000\") { #{item} }"
          end) <> " }"

      conn = build_conn() |> post("/api/graphql", %{"query" => bomb})
      body = json_response(conn, 200)

      assert %{"errors" => errors} = body
      refute Map.has_key?(body, "data")

      assert Enum.any?(errors, fn e ->
               String.contains?(e["message"] || "", "Operation is too complex")
             end)
    end

    test "正常查询不受影响" do
      conn =
        build_conn()
        |> post("/api/graphql", %{"query" => "{ __typename }"})

      assert %{"data" => %{"__typename" => "RootQueryType"}} = json_response(conn, 200)
    end
  end

  describe "token_limit: 5_000" do
    test "超大 document 在 parse 层被拒" do
      # 6000 个字段名 token + 大括号 ≈ 6002 > 5_000；token_limit 在 parse 阶段
      # 拦截，先于 validation（字段冲突）与 complexity 分析，防的是解析开销本身。
      bomb = "{ " <> String.duplicate("pendingApprovalsCount ", 6000) <> "}"

      conn = build_conn() |> post("/api/graphql", %{"query" => bomb})
      body = json_response(conn, 200)

      assert %{"errors" => errors} = body
      refute Map.has_key?(body, "data")

      # lexer 层错误消息（Absinthe.Phase.Parse: "Token limit exceeded"）——
      # 证明拦截发生在 parse 阶段，而非其后的 complexity 分析
      assert Enum.any?(errors, fn e ->
               String.contains?(e["message"] || "", "Token limit exceeded")
             end)
    end
  end
end
