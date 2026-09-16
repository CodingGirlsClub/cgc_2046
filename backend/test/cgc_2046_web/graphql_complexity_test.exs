defmodule Cgc2046Web.GraphqlComplexityTest do
  use Cgc2046Web.ConnCase, async: true

  # #297.1：GraphQL 查询成本限制（router @graphql_abuse_opts，非 dev 生效）。
  # test env（dev_routes=false）与 prod 同配置——本测试验证限制行为，防止回归。
  # 拒绝语义为 HTTP 200 + GraphQL errors（resolution 跳过、响应无 data 键），
  # 与 introspection guard 口径一致（标准 GraphQL 错误通道，非字面 4xx）。

  # 上限历史：250 → 1_000（016）→ 2_000（2026-09-15：小程序
  # MyEnrollments@100 / Catalog@50 实测 1_4xx/1_350，1_000 拒绝了已发布客户端）
  # → 4_000（2026-09-16：web 端四个 first:250 列表文档实测 3_0xx–3_5xx，
  # 2_000 拒绝了已发布客户端，工作台/公开课程+活动四页全挂）。
  # 见 router @graphql_abuse_opts 注释。测试数值随上限同比放大，机制断言不变。
  describe "max_complexity: 4_000" do
    test "别名字段炸弹由 token_limit 在 lexer 层拦截（complexity 分析之前）" do
      # 4200 个 alias 化顶层标量字段：complexity 4200 > 4000，但 token 数先超
      # 5_000 → 由 lexer 层 token_limit 截断（这正是两层防护的分工：解析开销
      # 须在 complexity 分析之前挡掉；见 router 注释）。
      bomb =
        "{ " <>
          Enum.map_join(0..4199, " ", fn i -> "a#{i}: pendingApprovalsCount" end) <> " }"

      conn = build_conn() |> post("/api/graphql", %{"query" => bomb})
      body = json_response(conn, 200)

      assert %{"errors" => errors} = body
      refute Map.has_key?(body, "data"), "resolution 必须被跳过，响应不应含 data"

      assert Enum.any?(errors, fn e ->
               String.contains?(e["message"] || "", "Token limit exceeded")
             end)
    end

    test "分页扇出由 complexity 上限拦截，错误含实际/上限值且不执行" do
      # 4 个 alias 化分页字段 × first=1300（ash_graphql 按 first × (字段数 + 2)
      # 折算）→ complexity 4 × 1300 × 2 = 10_400 > 4_000，token 数远低于 5_000
      # → 命中 complexity 层。
      # （分页 first 才是第一方真实成本的驱动：LIST_EVENTS@250=3500 的同款机制。）
      bomb =
        "{ " <>
          Enum.map_join(0..3, " ", fn i ->
            "a#{i}: listEvents(first: 1300) { results { id } }"
          end) <> " }"

      conn = build_conn() |> post("/api/graphql", %{"query" => bomb})
      body = json_response(conn, 200)

      assert %{"errors" => errors} = body
      refute Map.has_key?(body, "data")

      assert Enum.any?(errors, fn e ->
               msg = e["message"] || ""

               String.contains?(msg, "too complex") and
                 String.contains?(msg, "maximum is 4000") and
                 Regex.match?(~r/complexity is \d+/, msg)
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
