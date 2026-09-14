defmodule Cgc2046Web.Plugs.OAuthRegisterQuotaTest do
  @moduledoc """
  OAuth 注册端点按 IP 配额（RFC 7591 §5）：成功注册吃满独立配额后 429 +
  Retry-After；配额 key 与 `/mcp` 失败节流分开定义——注册被限流不影响凭证认证
  面，反之亦然（KTD8/Risk 分桶要求）。
  """
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.OAuthFixtures, as: OAuth
  alias Cgc2046Web.Plugs.OAuthRegisterQuotaPlug

  @default_config [max_attempts: 999_999, window_seconds: 3600]

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, OAuthRegisterQuotaPlug, max_attempts: 2, window_seconds: 3600)

    on_exit(fn ->
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
      Application.put_env(:cgc_2046, OAuthRegisterQuotaPlug, @default_config)
    end)

    :ok
  end

  test "成功注册计入配额：第 3 次 429 + Retry-After，且不影响 /mcp 鉴权面" do
    for i <- 1..2 do
      {conn, _body} = OAuth.register_client(["http://127.0.0.1:#{1000 + i}/cb"])
      assert conn.status == 201
    end

    {conn, body} = OAuth.register_client(["http://127.0.0.1:19999/cb"])

    assert conn.status == 429
    assert body["error"] == "rate_limited"
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0

    # 独立桶：注册配额被吃满后，/mcp 的失败认证仍按自己的分桶判定（401 而非 429）
    mcp_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer cgc_invalid_after_quota")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/mcp", OAuth.initialize_body())

    assert mcp_conn.status == 401

    # 元数据发现面完全不受配额影响（只拦 POST /oauth/register）
    assert get(build_conn(), "/.well-known/oauth-protected-resource").status == 200
  end

  test "失败注册同样计入配额（非 loopback 试探不免费）" do
    for _ <- 1..2 do
      {conn, _body} = OAuth.register_client(["https://evil.example.com/cb"])
      assert conn.status == 400
    end

    {conn, body} = OAuth.register_client(["http://127.0.0.1:19876/cb"])
    assert conn.status == 429
    assert body["error"] == "rate_limited"
  end
end
