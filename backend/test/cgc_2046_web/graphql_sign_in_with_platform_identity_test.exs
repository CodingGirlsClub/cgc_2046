defmodule Cgc2046Web.GraphqlSignInWithPlatformIdentityTest do
  # async: false —— openid 桶专项用例要调低全局 :rate_limits（同 graphql_sign_in_with_platform_rate_limit_test）。
  use Cgc2046Web.ConnCase, async: false

  alias AshAuthentication.Jwt
  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  # #930 回访静默登录：已绑定本平台身份（openid）的账号只用 wx.login 的 code 就能登录——
  # 不弹手机号授权、不调计费的手机号接口；首次登录仍必须走手机号（手机号是账号锚）。
  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    previous = Application.get_env(:cgc_2046, :rate_limits)

    on_exit(fn ->
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
      Application.put_env(:cgc_2046, :rate_limits, previous)
    end)

    :ok
  end

  defp post_query(query) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp phone_sign_in(code) do
    post_query("""
    mutation { signInWithPlatform(platform: "wechat", code: "#{code}", phoneCode: "pc-#{code}") { id } }
    """)
  end

  defp silent_sign_in(code, platform \\ "wechat") do
    post_query("""
    mutation { signInWithPlatformIdentity(platform: "#{platform}", code: "#{code}") { id email isPlatformAdmin } }
    """)
  end

  # 同一个人每次 wx.login 拿到的 code 不同、openid 相同：openid 取 code 的「人」前缀
  defp stub_person(openid) do
    Fixtures.stub_code2session(%{
      wechat: fn _conn ->
        Fixtures.code2session_body(:wechat, %{
          openid: openid,
          session_key: Fixtures.new_session_key()
        })
      end
    })
  end

  defp stub_phone_api do
    test_pid = self()

    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
        send(test_pid, :phone_api_called)

        Tesla.Mock.json(%{
          "errcode" => 0,
          "phone_info" => %{"purePhoneNumber" => "13800009311", "countryCode" => "86"}
        })
    end)
  end

  test "回访用户（本平台已绑定 openid）静默登录：签发带 platform claim 的会话，不调计费的手机号接口" do
    stub_person("w-silent-1")
    stub_phone_api()

    first = phone_sign_in("first")
    assert %{"data" => %{"signInWithPlatform" => %{"id" => user_id}}} = json_response(first, 200)
    assert_received :phone_api_called

    conn = silent_sign_in("again")

    assert %{"data" => %{"signInWithPlatformIdentity" => %{"id" => ^user_id}}} =
             json_response(conn, 200)

    refute_received :phone_api_called, "静默登录不得调用计费的手机号接口"

    cookie = conn.resp_cookies["cgc_token"]
    assert cookie && cookie.http_only
    {:ok, claims} = Jwt.peek(cookie.value)
    assert claims["platform"] == "wechat"
  end

  test "本平台没有绑定身份（首次登录）→ platform_identity_not_found，不签发会话" do
    stub_person("w-silent-new")

    conn = silent_sign_in("first-time")
    body = json_response(conn, 200)

    assert [%{"code" => "platform_identity_not_found"}] = body["errors"], inspect(body)
    assert conn.resp_cookies["cgc_token"] == nil
  end

  test "code 无效 / 平台非法 → authentication_failed（不泄露原因）" do
    Fixtures.stub_code2session(%{wechat: Fixtures.code2session_error_body(:wechat)})

    assert [%{"code" => "authentication_failed"}] =
             json_response(silent_sign_in("bad"), 200)["errors"]

    assert [%{"code" => "authentication_failed"}] =
             json_response(silent_sign_in("x", "qq"), 200)["errors"]
  end

  test "与手机号登录共用 openid 桶（#930）：同一 openid 两种登录合计超限即限流" do
    Application.put_env(:cgc_2046, :rate_limits,
      platform_sign_in_ip: 100,
      platform_sign_in_openid: 2,
      notification_consent_actor: 100
    )

    stub_person("w-silent-bucket")
    stub_phone_api()

    assert %{"data" => %{"signInWithPlatform" => %{"id" => _}}} =
             json_response(phone_sign_in("a"), 200)

    assert %{"data" => %{"signInWithPlatformIdentity" => %{"id" => _}}} =
             json_response(silent_sign_in("b"), 200)

    body = json_response(silent_sign_in("c"), 200)
    assert Enum.any?(body["errors"] || [], &(&1["code"] == "rate_limited")), inspect(body)
  end
end
