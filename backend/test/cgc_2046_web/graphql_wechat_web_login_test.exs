defmodule Cgc2046Web.GraphqlWechatWebLoginTest do
  @moduledoc """
  微信扫码登录 GraphQL 层覆盖（plan 002 U4）。

  - wechatLoginStart：出码 URL（state + TTL）、未配置门禁、限流
  - signInWithWechat：已绑定直登（cookie）、unionid 跨应用合并、未绑定转
    needs_binding、state 重放/过期拒绝、code 换 token 失败
  - bindWechatWithPhone：绑定全流程（自动建号 + identity 落库 + cookie）、
    错 ticket 拒绝
  """
  use Cgc2046Web.ConnCase, async: false

  alias AshAuthentication.Jwt
  alias Cgc2046.Accounts.UserIdentity

  require Ash.Query

  @stub Cgc2046.WechatWebStub
  @phone_raw "13800137000"
  @phone "+8613800137000"

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())

    on_exit(fn ->
      :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    end)

    {:ok, login: start_login()}
  end

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  # test.exs 注入了 wechat_web_req_plug stub；wechat_web 配置沿用 config.exs
  # dummy 值（configured? true），OAuth 请求全被 Req.Test 拦截。
  defp start_login do
    conn =
      build_conn()
      |> graphql_post("""
      mutation { wechatLoginStart { qrUrl state expiresInSeconds } }
      """)

    res = json_response(conn, 200)
    assert %{"data" => %{"wechatLoginStart" => start}} = res
    assert String.starts_with?(start["qrUrl"], "https://open.weixin.qq.com/connect/qrconnect")
    assert start["qrUrl"] =~ "state=" <> start["state"]
    assert start["qrUrl"] =~ "scope=snsapi_login"
    assert start["expiresInSeconds"] > 0

    # M2：state 经 httpOnly cgc_wechat_state cookie 绑定发起浏览器
    state_cookie = conn.resp_cookies["cgc_wechat_state"]
    assert state_cookie != nil
    assert state_cookie.http_only == true
    assert state_cookie.value == start["state"]

    {start["state"], state_cookie.value}
  end

  # M2：携带浏览器 state cookie 的回调/绑定请求
  defp with_wechat_cookie(conn, state_cookie) do
    put_req_cookie(conn, "cgc_wechat_state", state_cookie)
  end

  defp stub_code2session(openid, unionid \\ nil) do
    Req.Test.stub(@stub, fn
      %{path_info: ["sns", "oauth2", "access_token"]} = conn ->
        Req.Test.json(conn, %{
          "access_token" => "at-#{openid}",
          "openid" => openid,
          "unionid" => unionid
        })

      %{path_info: ["sns", "userinfo"]} = conn ->
        Req.Test.json(conn, %{"openid" => openid, "nickname" => "wuser"})
    end)
  end

  defp sign_in_with_wechat_mutation(code, state) do
    """
    mutation {
      signInWithWechat(code: "#{code}", state: "#{state}") {
        status
        bindTicket
      }
    }
    """
  end

  describe "wechatLoginStart" do
    test "出码 URL + state + TTL（setup 已断言，此处补 state 唯一性）", %{login: {state, _sc}} do
      {state2, _sc2} = start_login()
      assert state != state2
    end

    test "next 透传：redirect_uri 携带 next 参数（state 无关 URL 透传）" do
      res =
        build_conn()
        |> graphql_post("""
        mutation { wechatLoginStart(next: "/orders/abc?from=enroll") { qrUrl } }
        """)
        |> json_response(200)

      assert %{"data" => %{"wechatLoginStart" => %{"qrUrl" => url}}} = res

      # redirect_uri 单层编码：%3Fnext%3D 即 ?next=，后跟单编码的 /orders/abc?from=enroll
      assert url =~ "wechat-callback%3Fnext%3D%2Forders%2Fabc%3Ffrom%3Denroll"
    end

    test "未配置门禁：wechat_login_unavailable" do
      Application.put_env(:cgc_2046, :wechat_web, appid: nil, secret: nil)

      res =
        build_conn()
        |> graphql_post("mutation { wechatLoginStart { qrUrl state expiresInSeconds } }")
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_login_unavailable"}]} = res

      Application.put_env(:cgc_2046, :wechat_web,
        appid: "test-wechat-web-appid",
        secret: "test-wechat-web-secret"
      )
    end

    test "IP 限流：21 次/15min 拒绝" do
      # setup 已 start 1 次；再补 19 次达 20 上限，第 21 次拒绝
      for _ <- 1..19, do: start_login()

      res =
        build_conn()
        |> graphql_post("mutation { wechatLoginStart { qrUrl } }")
        |> json_response(200)

      assert %{"errors" => [%{"code" => "rate_limited"}]} = res
    end
  end

  describe "signInWithWechat" do
    test "未绑定：needs_binding + bindTicket（=state）", %{login: {state, sc}} do
      stub_code2session("web-openid-new", "union-1")

      res =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("code-1", state))
        |> json_response(200)

      assert %{
               "data" => %{
                 "signInWithWechat" => %{"status" => "NEEDS_BINDING", "bindTicket" => ticket}
               }
             } =
               res

      assert ticket == state
    end

    test "state 重放拒绝：同一 state 第二次回调失败", %{login: {state, sc}} do
      stub_code2session("web-openid-replay", "union-2")

      build_conn()
      |> with_wechat_cookie(sc)
      |> graphql_post(sign_in_with_wechat_mutation("code-1", state))
      |> json_response(200)

      res =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("code-1", state))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_sign_in_failed"}]} = res
    end

    test "M2 无浏览器 cookie：合法 state+code 也拒绝（钓鱼链接防护）", %{login: {state, _sc}} do
      stub_code2session("web-openid-phish", nil)

      res =
        build_conn()
        |> graphql_post(sign_in_with_wechat_mutation("code-phish", state))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_sign_in_failed"}]} = res
    end

    test "M2 cookie 不匹配（他浏览器 state）：拒绝", %{login: {state, _sc}} do
      stub_code2session("web-openid-mismatch", nil)

      res =
        build_conn()
        |> with_wechat_cookie(Ecto.UUID.generate())
        |> graphql_post(sign_in_with_wechat_mutation("code-mm", state))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_sign_in_failed"}]} = res
    end

    test "state 不存在：统一 wechat_sign_in_failed" do
      stub_code2session("web-openid-x", nil)

      res =
        build_conn()
        |> graphql_post(sign_in_with_wechat_mutation("code-x", Ecto.UUID.generate()))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_sign_in_failed"}]} = res
    end

    test "code 换 token 失败（errcode 非零）→ wechat_sign_in_failed", %{login: {state, sc}} do
      Req.Test.stub(@stub, fn
        %{path_info: ["sns", "oauth2", "access_token"]} = conn ->
          Req.Test.json(conn, %{"errcode" => 40_063, "errmsg" => "invalid code"})

        %{path_info: ["sns", "userinfo"]} = conn ->
          Req.Test.json(conn, %{"openid" => "x"})
      end)

      res =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("bad-code", state))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "wechat_sign_in_failed"}]} = res
    end

    test "绑定后直登：SIGNED_IN + httpOnly cookie" do
      # 先走 needs_binding 拿 ticket 并完成绑定
      {state, sc} = start_login()
      stub_code2session("web-openid-direct", "union-direct")

      # 先触发 needs_binding（ticket 迁移）再完成绑定
      res0 =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("code-0", state))
        |> json_response(200)

      assert %{"data" => %{"signInWithWechat" => %{"status" => "NEEDS_BINDING"}}} = res0
      complete_binding(state, sc)

      # 第二次扫码：同 openid 已有 identity → 直登
      {state2, sc2} = start_login()

      conn =
        build_conn()
        |> with_wechat_cookie(sc2)
        |> graphql_post(sign_in_with_wechat_mutation("code-2", state2))

      res = json_response(conn, 200)

      assert %{"data" => %{"signInWithWechat" => %{"status" => "SIGNED_IN", "bindTicket" => nil}}} =
               res

      cookie = conn.resp_cookies["cgc_token"]
      assert cookie != nil and cookie.http_only == true
      {:ok, claims} = Jwt.peek(cookie.value)
      assert claims["purpose"] == "user"
      # M8：web 面 token 带 platform=web claim（吊销面过滤依据）
      assert claims["platform"] == "web"
    end

    test "unionid 跨应用合并：已有小程序 wechat identity 同 unionid → 直登" do
      # 造一个小程序 identity 用户（内部路径）
      {:ok, mp_identity_user} = create_mp_user_with_unionid(@phone, "union-shared")

      {state, sc} = start_login()
      stub_code2session("web-openid-mp-merge", "union-shared")

      conn =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("code-3", state))

      res = json_response(conn, 200)

      assert %{"data" => %{"signInWithWechat" => %{"status" => "SIGNED_IN"}}} = res

      cookie = conn.resp_cookies["cgc_token"]
      {:ok, claims} = Jwt.peek(cookie.value)
      assert claims["sub"] == "user?id=" <> mp_identity_user.id
    end
  end

  describe "bindWechatWithPhone" do
    test "绑定全流程：验码 → 建号 → identity 落库 → 消费 ticket → cookie" do
      {state, sc} = start_login()
      stub_code2session("web-openid-bind", "union-bind")

      # 先触发 needs_binding（ticket 迁移）
      res =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post(sign_in_with_wechat_mutation("code-b", state))
        |> json_response(200)

      assert %{"data" => %{"signInWithWechat" => %{"status" => "NEEDS_BINDING"}}} = res

      code = issue_bind_code()

      conn =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post("""
        mutation {
          bindWechatWithPhone(bindTicket: "#{state}", phone: "#{@phone_raw}", code: "#{code}") {
            id
            email
            isPlatformAdmin
          }
        }
        """)

      res2 = json_response(conn, 200)

      assert %{"data" => %{"bindWechatWithPhone" => payload}} = res2
      assert is_binary(payload["id"])
      assert is_nil(payload["email"])

      cookie = conn.resp_cookies["cgc_token"]
      assert cookie != nil and cookie.http_only == true

      # identity 落库（provider wechat_web, uid openid, unionid）
      {:ok, identity} =
        UserIdentity
        |> Ash.Query.filter(provider == :wechat_web and uid == "web-openid-bind")
        |> Ash.read_one(authorize?: false)

      assert identity != nil
      assert identity.unionid == "union-bind"
      assert identity.user_id == payload["id"]
    end

    test "错码：invalid_or_expired_code + ticket 可重试（M3：验码失败不烧 ticket）", %{login: {state, sc}} do
      stub_code2session("web-openid-bad", nil)

      build_conn()
      |> with_wechat_cookie(sc)
      |> graphql_post(sign_in_with_wechat_mutation("code-c", state))
      |> json_response(200)

      res =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post("""
        mutation {
          bindWechatWithPhone(bindTicket: "#{state}", phone: "#{@phone_raw}", code: "000000") {
            id
          }
        }
        """)
        |> json_response(200)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "invalid_or_expired_code"))

      # M3：错码一次不烧 ticket——正确码重试仍可完成绑定
      code = issue_bind_code()

      res2 =
        build_conn()
        |> with_wechat_cookie(sc)
        |> graphql_post("""
        mutation {
          bindWechatWithPhone(bindTicket: "#{state}", phone: "#{@phone_raw}", code: "#{code}") { id }
        }
        """)
        |> json_response(200)

      assert %{"data" => %{"bindWechatWithPhone" => %{"id" => _}}} = res2
    end

    test "无效 ticket（不存在）：invalid_bind_ticket（cookie 与 ticket 同值但 DB 无记录）" do
      res =
        build_conn()
        |> with_wechat_cookie("bogus-ticket")
        |> graphql_post("""
        mutation {
          bindWechatWithPhone(bindTicket: "bogus-ticket", phone: "#{@phone_raw}", code: "123456") {
            id
          }
        }
        """)
        |> json_response(200)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "invalid_bind_ticket"))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp issue_bind_code do
    {:ok, code, _rid} = Cgc2046.Accounts.PhoneVerificationCode.issue(@phone, :wechat_bind)
    code
  end

  defp complete_binding(state, state_cookie) do
    code = issue_bind_code()

    build_conn()
    |> with_wechat_cookie(state_cookie)
    |> graphql_post("""
    mutation {
      bindWechatWithPhone(bindTicket: "#{state}", phone: "#{@phone_raw}", code: "#{code}") { id }
    }
    """)
    |> json_response(200)
  end

  defp create_mp_user_with_unionid(phone, unionid) do
    # 内部建号（register_with_miniprogram 需 ash_authentication 私有 context）
    {:ok, user} =
      Cgc2046.Accounts.User
      |> Ash.Changeset.for_create(:register_with_miniprogram, %{phone: phone})
      |> Ash.create(context: %{private: %{ash_authentication?: true}})

    UserIdentity
    |> Ash.Changeset.for_create(:upsert, %{
      provider: :wechat,
      uid: "mp-openid-" <> unionid,
      unionid: unionid,
      user_id: user.id
    })
    |> Ash.create(context: %{private: %{ash_authentication?: true}})

    {:ok, user}
  end
end
