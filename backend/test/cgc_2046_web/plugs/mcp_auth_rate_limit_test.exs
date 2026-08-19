defmodule Cgc2046Web.Plugs.McpAuthRateLimitTest do
  @moduledoc """
  MCP 失败认证节流（#214）：按 remote_ip 计失败 Bearer 认证次数，
  超限 401 → 429 + Retry-After，防连接 token 暴力试探。

  - plug 级：连续失败吃满预算后第 N+1 次 429；有效 token 不受节流影响
  - endpoint 级：经 /mcp pipeline 全链路钉住 wiring（router → auth）
  """
  # async: false —— 全局 ETS 表 :cgc_rate_limiter + put_env 全局 max_attempts
  # （同 graphql_invitation_rate_limit_test.exs）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046Web.Plugs.McpAuthPlug

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"rate-limit-test","version":"0.0.0"}}})

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.McpAuthPlug, max_attempts: 3)

    on_exit(fn ->
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.McpAuthPlug, max_attempts: 999_999)
    end)

    :ok
  end

  defp call_plug(conn), do: McpAuthPlug.call(conn, McpAuthPlug.init([]))

  defp failed_attempt(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> call_plug()
  end

  defp issue_plain_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "rate limit test"}, actor: user)
      |> Ash.create()

    token.__metadata__[:plain_token]
  end

  describe "plug 级" do
    test "失败认证吃满预算前 401，超限后 429 + Retry-After" do
      for i <- 1..3 do
        conn = failed_attempt("cgc_invalid_#{i}")
        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") != []
      end

      conn = failed_attempt("cgc_invalid_4")

      assert conn.halted
      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert conn.resp_body =~ "rate_limited"
    end

    test "节流只计失败：被限流 IP 上有效 token 仍放行" do
      user = Fixtures.register_user("mcp-rate-valid")
      plain = issue_plain_token(user)

      # 同 IP（127.0.0.1）先吃满失败预算
      for i <- 1..3, do: failed_attempt("cgc_invalid_#{i}")
      assert failed_attempt("cgc_invalid_4").status == 429

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{plain}")
        |> call_plug()

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end
  end

  describe "endpoint 级（/mcp pipeline wiring）" do
    test "无效 Bearer 连续 4 次 → 前 3 次 401，第 4 次 429" do
      post_initialize = fn token ->
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> post("/mcp", @initialize_body)
      end

      for i <- 1..3 do
        assert post_initialize.("cgc_invalid_#{i}").status == 401
      end

      conn = post_initialize.("cgc_invalid_4")

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end
  end
end
