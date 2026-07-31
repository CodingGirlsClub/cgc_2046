defmodule Cgc2046Web.HttpCase do
  @moduledoc """
  HTTP 集成测试夹具(接缝 1 主链路)。

  所有后端 TDD 用例从 HTTP 层打:`/api/graphql`(以及后续的 `/api/v1/*` REST),
  带真实 Bearer token,经完整链路(plug 认证 → Ash actions/policies → 多租户),
  才能测到 401/403 语义。本模块提供:

  - `graphql_query/4`:向 GraphQL 端点发查询,返回解码后的响应体
  - `graphql_request/4`:低层请求,返回原始 conn(供断言状态码等)
  - `with_bearer_token/2`:给请求附加 Bearer 认证头

  > 与 `Cgc2046Web.ConnCase` 的区别:ConnCase 是脚手架默认的 controller 级
  > 测试用例(测试 ErrorJSON 等纯函数);HttpCase 是集成级主接缝。
  """

  use ExUnit.CaseTemplate

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint Cgc2046Web.Endpoint

  using do
    quote do
      @endpoint Cgc2046Web.Endpoint

      use Cgc2046Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Cgc2046Web.HttpCase

      alias Cgc2046.Repo
    end
  end

  setup tags do
    Cgc2046.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  向 `/api/graphql` 发送 GraphQL 查询。

  ## Options
  - `:status` - 期望的 HTTP 状态码(默认 200),不匹配则断言失败
  - `:headers` - 附加请求头列表(如 `[{"authorization", "Bearer xxx"}]`)

  返回解码后的 JSON 响应体(map)。
  """
  def graphql_query(conn, query, variables \\ %{}, opts \\ []) do
    conn
    |> graphql_request(query, variables, opts)
    |> json_response(Keyword.get(opts, :status, 200))
  end

  @doc """
  向 `/api/graphql` 发送 GraphQL 查询,返回原始 conn。

  用于需要断言状态码/响应头,或需要手动 `json_response/2` 的用例。
  """
  def graphql_request(conn, query, variables \\ %{}, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(%{query: query, variables: variables}))
  end

  @doc "为请求附加 Bearer 认证头(Bearer token 由 T02 认证落地后生成)。"
  def with_bearer_token(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
