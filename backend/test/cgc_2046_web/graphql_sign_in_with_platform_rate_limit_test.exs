defmodule Cgc2046Web.GraphqlSignInWithPlatformRateLimitTest do
  # async: false —— RateLimit 用全局 ETS 表 :cgc_rate_limiter，
  # async: true 会与其他测试的限流计数互相污染（同 graphql_invitation_rate_limit_test.exs）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 3)

    on_exit(fn ->
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999)
    end)

    :ok
  end

  defp sign_in_mutation(platform) do
    """
    mutation {
      signInWithPlatform(platform: "#{platform}", code: "bad-code", encryptedData: "x", iv: "y") {
        id
      }
    }
    """
  end

  defp post_mutation(platform) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => sign_in_mutation(platform)})
    |> json_response(200)
  end

  test "signInWithPlatform 挂载 RateLimit（getPhoneNumber 计费防刷，plan §7）" do
    # 平台侧拒绝 code（每次尝试都走完整策略调用但被平台拒绝）
    Fixtures.stub_code2session(%{wechat: Fixtures.code2session_error_body(:wechat)})

    # 前 3 次：认证失败（authentication_failed），非限流
    for _ <- 1..3 do
      res = post_mutation("wechat")

      assert %{"errors" => [%{"code" => "authentication_failed"}]} = res,
             "前 3 次应为认证失败而非限流，实际 #{inspect(res)}"
    end

    # 第 4 次：触发限流（同一 IP + platform 桶，max_attempts=3）
    res = post_mutation("wechat")

    assert Enum.any?(res["errors"], &(&1["code"] == "rate_limited")),
           "第 4 次应被限流（rate_limited），实际 #{inspect(res)}"
  end
end
