defmodule Cgc2046Web.HttpIntegrationTest do
  @moduledoc """
  T01 切片A(红→绿):HTTP 集成测试夹具可用。

  验证接缝 1(主):所有后端 TDD 用例从 HTTP 层打 —— 经真实 Phoenix 路由、
  GraphQL 端点,返回真实响应体。本切片用脚手架自带的 `ping` 查询证明
  夹具链路(conn 构建 → 请求 → 解码)端到端可用。
  """

  use Cgc2046Web.HttpCase, async: true

  test "GraphQL ping 经真实 HTTP 链路返回 pong" do
    assert graphql_query(build_conn(), "{ ping }") == %{"data" => %{"ping" => "pong"}}
  end

  test "graphql_query 支持显式指定期望状态码与变量" do
    body = graphql_query(build_conn(), "{ ping }", %{}, status: 200)

    assert body["data"]["ping"] == "pong"
  end
end
