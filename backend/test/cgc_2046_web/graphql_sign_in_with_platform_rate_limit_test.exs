defmodule Cgc2046Web.GraphqlSignInWithPlatformRateLimitTest do
  # async: false —— RateLimit 用全局 ETS 表 :cgc_rate_limiter 与全局 app env（:rate_limits），
  # async: true 会与其他测试的限流计数互相污染（同 graphql_invitation_rate_limit_test.exs）。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  # #930 登录与订阅授权拆桶：
  # - 登录的 IP 维度只留宽松天花板（线下活动同一 WiFi / CGNAT 下多人依次登录）；
  # - 计费防刷按 openid 计（code2session 之后、换手机号之前——被拦下的请求不打计费接口）；
  # - 订阅授权本来就要求登录，按账号计，不再与登录共用「IP + 平台」桶。
  # 专项测试把三个具名上限调小，验证各自生效且互不影响。
  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    previous = Application.get_env(:cgc_2046, :rate_limits)

    put_limits(platform_sign_in_ip: 6, platform_sign_in_openid: 3, notification_consent_actor: 4)

    on_exit(fn ->
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())

      if previous,
        do: Application.put_env(:cgc_2046, :rate_limits, previous),
        else: Application.delete_env(:cgc_2046, :rate_limits)
    end)

    :ok
  end

  defp put_limits(limits), do: Application.put_env(:cgc_2046, :rate_limits, limits)

  defp post_query(query, token \\ nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    end)
    |> post("/api/graphql", %{"query" => query})
  end

  defp sign_in(code) do
    post_query("""
    mutation {
      signInWithPlatform(platform: "wechat", code: "#{code}", phoneCode: "pc-#{code}") { id }
    }
    """)
  end

  defp grant(token) do
    post_query(
      """
      mutation {
        grantMiniProgramNotificationConsent(platform: "wechat", templateKey: "approval_result")
      }
      """,
      token
    )
    |> json_response(200)
  end

  defp signed_in?(conn),
    do: match?(%{"data" => %{"signInWithPlatform" => %{"id" => _}}}, json_response(conn, 200))

  defp rate_limited?(conn), do: rate_limited_body?(json_response(conn, 200))

  defp rate_limited_body?(body),
    do: Enum.any?(body["errors"] || [], &(&1["code"] == "rate_limited"))

  # 每个 js_code 一个 openid：同一 IP 下的不同人（或同一人反复用同一 code 前缀）
  defp stub_people do
    Fixtures.stub_code2session(%{
      wechat: fn conn ->
        Fixtures.code2session_body(:wechat, %{
          openid: "w-rl-" <> conn.query_params["js_code"],
          session_key: Fixtures.new_session_key()
        })
      end
    })
  end

  # 计费的手机号接口（getuserphonenumber）：每次命中回报给测试进程
  defp stub_phone_api do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
        send(test_pid, :phone_api_called)

        Tesla.Mock.json(%{
          "errcode" => 0,
          "phone_info" => %{"purePhoneNumber" => "13800009301", "countryCode" => "86"}
        })
    end)
  end

  test "同一 IP 多人依次登录：不受旧的「5 次 / 15 分钟」所限，只在宽松天花板处限流" do
    stub_people()
    stub_phone_api()

    for i <- 1..6 do
      assert signed_in?(sign_in("person-#{i}")), "同一 IP 第 #{i} 位应登录成功"
    end

    assert rate_limited?(sign_in("person-7")), "超过 IP 天花板（本测试调为 6）应限流"
  end

  test "登录后接受 3 个订阅模板，再次登录不被拒（两个接口不再共用一个桶）" do
    put_limits(platform_sign_in_ip: 2, platform_sign_in_openid: 5, notification_consent_actor: 5)
    stub_people()
    stub_phone_api()

    conn = sign_in("subscriber")
    assert signed_in?(conn)
    token = conn.resp_cookies["cgc_token"].value

    for _ <- 1..3 do
      assert is_integer(grant(token)["data"]["grantMiniProgramNotificationConsent"])
    end

    # IP 桶只计了 1 次登录（订阅授权不再计入）→ 第 2 次登录照常放行
    assert signed_in?(sign_in("subscriber"))
  end

  test "单个 openid 高频登录：超过上限即限流，且被拦下的请求不触发计费的手机号接口" do
    stub_people()
    stub_phone_api()

    for _ <- 1..3 do
      assert signed_in?(sign_in("same-person"))
      assert_received :phone_api_called
    end

    assert rate_limited?(sign_in("same-person")), "同一 openid 第 4 次（上限 3）应限流"
    refute_received :phone_api_called, "被限流的请求不得调用计费的手机号接口"

    # 同一 IP 的另一个人不受影响（openid 桶按人计）
    assert signed_in?(sign_in("someone-else"))
  end

  test "无效 code 连续失败：拿不到 openid，由 IP 天花板兜底" do
    Fixtures.stub_code2session(%{wechat: Fixtures.code2session_error_body(:wechat)})

    for i <- 1..6 do
      body = json_response(sign_in("bad-#{i}"), 200)

      assert [%{"code" => "authentication_failed"}] = body["errors"],
             "前 6 次应为认证失败而非限流，实际 #{inspect(body)}"
    end

    assert rate_limited?(sign_in("bad-7"))
  end

  test "订阅授权按账号计：一人超限不影响同 IP 的另一人，也不影响登录" do
    put_limits(platform_sign_in_ip: 10, platform_sign_in_openid: 5, notification_consent_actor: 2)
    stub_people()
    stub_phone_api()

    token_a = sign_in("consent-a").resp_cookies["cgc_token"].value

    for _ <- 1..2,
        do: assert(is_integer(grant(token_a)["data"]["grantMiniProgramNotificationConsent"]))

    assert rate_limited_body?(grant(token_a)), "同一账号第 3 次（上限 2）应限流"

    # 另一个账号：不同手机号 → 不同 User（手机号是账号锚）
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
        Tesla.Mock.json(%{
          "errcode" => 0,
          "phone_info" => %{"purePhoneNumber" => "13800009302", "countryCode" => "86"}
        })
    end)

    token_b = sign_in("consent-b").resp_cookies["cgc_token"].value
    assert is_integer(grant(token_b)["data"]["grantMiniProgramNotificationConsent"])
    assert signed_in?(sign_in("consent-c"))
  end
end
