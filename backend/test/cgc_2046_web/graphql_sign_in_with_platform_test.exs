defmodule Cgc2046Web.GraphqlSignInWithPlatformTest do
  @moduledoc """
  `signInWithPlatform` mutation 的 GraphQL 层覆盖（Phase 1 身份基座，N1 一键登录）。

  与 signIn 同一交付路径：token 经 httpOnly cookie（路径 B），响应体不含 token。
  覆盖：成功登录 + cookie 写入 + platform claim、me 联动、失败统一
  authentication_failed、session_key 不出现在任何响应体（红线）。
  """
  use Cgc2046Web.ConnCase, async: true

  alias AshAuthentication.Jwt
  alias Cgc2046.MiniprogramFixtures, as: Fixtures

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp sign_in_mutation(platform, code, encrypted_data, iv) do
    """
    mutation {
      signInWithPlatform(
        platform: "#{platform}"
        code: "#{code}"
        encryptedData: "#{encrypted_data}"
        iv: "#{iv}"
      ) {
        id
        email
        isPlatformAdmin
      }
    }
    """
  end

  # 与 graphql_auth_test.exs 的 assert_auth_cookie_written 同源的正向范式；
  # 本文件独立断言平台登录路径（7 天 max_age 对齐 token_lifetime 7d）。
  defp assert_auth_cookie_written(conn) do
    cookie = conn.resp_cookies["cgc_token"]
    assert cookie != nil, "expected cgc_token cookie to be written by before_send"
    assert cookie.http_only == true, "cgc_token must be httpOnly (防 JS 读取)"
    assert cookie.same_site == "Lax", "cgc_token sameSite 应为 Lax"
    assert is_binary(cookie.value) and byte_size(cookie.value) > 0, "cgc_token 值非空"

    assert cookie.max_age == 60 * 60 * 24 * 7,
           "cgc_token max_age 应为 7 天对齐 token_lifetime（Phase 1: 14d→7d），实际 #{inspect(cookie.max_age)}"

    cookie
  end

  defp wechat_success_fixture(phone, openid) do
    session_key = Fixtures.new_session_key()

    body =
      Fixtures.code2session_body(:wechat, %{openid: openid, session_key: session_key})

    {encrypted_data, iv} =
      Fixtures.encrypt_phone(session_key, Fixtures.phone_payload(phone))

    Fixtures.stub_code2session(%{wechat: body})
    {encrypted_data, iv}
  end

  test "wechat 一键登录成功：返回用户 + httpOnly cookie（platform claim）" do
    {encrypted_data, iv} = wechat_success_fixture("13800000020", "w-gql-1")

    conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-1", encrypted_data, iv))

    res = json_response(conn, 200)

    res = json_response(conn, 200)
    assert %{"data" => %{"signInWithPlatform" => payload}} = res
    assert is_binary(payload["id"])
    # 小程序手机号用户无邮箱 → email 为 null（users.email 已放宽可空）
    assert is_nil(payload["email"])
    assert payload["isPlatformAdmin"] == false

    # token 经 httpOnly cookie 交付，且带 platform claim（JWT 平台作用域）
    cookie = assert_auth_cookie_written(conn)
    {:ok, claims} = Jwt.peek(cookie.value)
    assert claims["platform"] == "wechat"
    assert claims["purpose"] == "user"
  end

  test "登录 cookie 可直接驱动 me 查询（email 可空不破坏 me）" do
    {encrypted_data, iv} = wechat_success_fixture("13800000021", "w-gql-2")

    conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-2", encrypted_data, iv))

    assert %{"data" => %{"signInWithPlatform" => %{"id" => id}}} = json_response(conn, 200)
    cookie = assert_auth_cookie_written(conn)

    me_conn =
      build_conn()
      |> put_req_cookie("cgc_token", cookie.value)
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => "{ me { id email isPlatformAdmin } }"})

    me_res = json_response(me_conn, 200)
    assert %{"data" => %{"me" => me}} = me_res
    assert me["id"] == id
    assert is_nil(me["email"])
    assert me["isPlatformAdmin"] == false
  end

  describe "phoneCode 新契约（getuserphonenumber）" do
    defp phone_code_mutation(platform, code, phone_code) do
      """
      mutation {
        signInWithPlatform(
          platform: "#{platform}"
          code: "#{code}"
          phoneCode: "#{phone_code}"
        ) {
          id
          email
          isPlatformAdmin
        }
      }
      """
    end

    defp stub_phone_code(phone \\ "13800001234", errcode \\ 0) do
      Tesla.Mock.mock(fn
        %{method: :post, url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
          Tesla.Mock.json(%{
            "errcode" => errcode,
            "phone_info" => %{"purePhoneNumber" => phone, "countryCode" => "86"}
          })
      end)
    end

    test "wechat + phoneCode 成功：SDK 直取手机号并锚定 +8613800001234" do
      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-gql-pc-1",
            session_key: Fixtures.new_session_key()
          })
      })

      stub_phone_code()

      conn =
        graphql_post(build_conn(), phone_code_mutation("wechat", "gql-pc-code-1", "pc-token-1"))

      res = json_response(conn, 200)
      assert %{"data" => %{"signInWithPlatform" => payload}} = res
      assert is_binary(payload["id"])
      assert is_nil(payload["email"])

      # phone 锚定：purePhoneNumber+countryCode 归一化为 +8613800001234
      # （phone-keyed find-or-create 的确定性前提；Repo 直读绕过 public?: false）
      user = Cgc2046.Repo.get!(Cgc2046.Accounts.User, payload["id"])
      assert user.phone == "+8613800001234"

      cookie = assert_auth_cookie_written(conn)
      {:ok, claims} = Jwt.peek(cookie.value)
      assert claims["platform"] == "wechat"
    end

    test "SDK errcode 非零：authentication_failed + 不写 cookie" do
      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-gql-pc-2",
            session_key: Fixtures.new_session_key()
          })
      })

      stub_phone_code("13800001234", 40029)

      conn =
        graphql_post(build_conn(), phone_code_mutation("wechat", "gql-pc-code-2", "pc-token-2"))

      res = json_response(conn, 200)

      assert [%{"code" => "authentication_failed"}] = res["errors"]
      assert conn.resp_cookies["cgc_token"] == nil
    end

    test "phone_code 缺且 encrypted_data/iv 缺：authentication_failed（组合校验 fail-closed）" do
      Fixtures.stub_code2session(%{
        wechat:
          Fixtures.code2session_body(:wechat, %{
            openid: "w-gql-pc-3",
            session_key: Fixtures.new_session_key()
          })
      })

      query = """
      mutation {
        signInWithPlatform(platform: "wechat", code: "gql-pc-code-3") {
          id
        }
      }
      """

      conn = graphql_post(build_conn(), query)
      assert [%{"code" => "authentication_failed"}] = json_response(conn, 200)["errors"]
    end

    test "tt 只给 phoneCode：authentication_failed（unsupported 组合 fail-closed）" do
      Fixtures.stub_code2session(%{
        tt:
          Fixtures.code2session_body(:tt, %{
            openid: "t-gql-pc-4",
            session_key: Fixtures.new_session_key()
          })
      })

      conn = graphql_post(build_conn(), phone_code_mutation("tt", "gql-pc-code-4", "pc-token-4"))
      assert [%{"code" => "authentication_failed"}] = json_response(conn, 200)["errors"]
    end
  end

  test "重登后旧 cookie 立即失效（重登吊销旧 jti 的端到端行为）" do
    # 同一 stub 服务两次登录 → 两份 encryptedData 共用同一 session_key
    session_key = Fixtures.new_session_key()

    body =
      Fixtures.code2session_body(:wechat, %{openid: "w-gql-revoke", session_key: session_key})

    Fixtures.stub_code2session(%{wechat: body})

    payload = Fixtures.phone_payload("13800000024")
    {ed1, iv1} = Fixtures.encrypt_phone(session_key, payload)
    {ed2, iv2} = Fixtures.encrypt_phone(session_key, payload)

    first_conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-r1", ed1, iv1))

    first_cookie = assert_auth_cookie_written(first_conn)

    # 第二次登录（同一平台账号）：签发新 token 并吊销旧 jti
    second_conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-r2", ed2, iv2))

    assert %{"data" => %{"signInWithPlatform" => %{"id" => _}}} =
             json_response(second_conn, 200)

    second_cookie = assert_auth_cookie_written(second_conn)
    assert second_cookie.value != first_cookie.value

    me_query = "{ me { id } }"

    # 旧 token：token 记录已被吊销（purpose=revocation）→ load_from_bearer 查不到
    # → 与 signOut 测试同构，me 返回 auth_uncertain（签名仍有效但 user 未加载）
    old_conn =
      build_conn()
      |> put_req_cookie("cgc_token", first_cookie.value)
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => me_query})

    old_res = json_response(old_conn, 200)

    assert %{"data" => %{"me" => nil}, "errors" => old_errors} = old_res

    assert Enum.any?(old_errors, &(&1["code"] == "auth_uncertain")),
           "重登后旧 token 应失效（auth_uncertain），实际 #{inspect(old_res)}"

    # 新 token 正常工作
    new_conn =
      build_conn()
      |> put_req_cookie("cgc_token", second_cookie.value)
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => me_query})

    assert %{"data" => %{"me" => %{"id" => _}}} = json_response(new_conn, 200)
  end

  test "平台拒绝 code：authentication_failed + 不写 cookie" do
    Fixtures.stub_code2session(%{wechat: Fixtures.code2session_error_body(:wechat)})

    conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "bad-code", "x", "y"))

    res = json_response(conn, 200)

    assert %{"data" => %{"signInWithPlatform" => nil}, "errors" => errors} = res

    assert [%{"message" => "Platform sign in failed", "code" => "authentication_failed"}] =
             errors

    refute conn.resp_cookies["cgc_token"], "失败不得写认证 cookie"
  end

  test "非法 platform 值：authentication_failed（不暴露内部细节）" do
    conn =
      graphql_post(build_conn(), sign_in_mutation("bogus", "code", "x", "y"))

    res = json_response(conn, 200)

    assert %{"data" => %{"signInWithPlatform" => nil}, "errors" => errors} = res
    assert [%{"code" => "authentication_failed"}] = errors
  end

  test "session_key 不出现在响应体（成功与解密失败两条路径）" do
    # 可识别的 16 字节 session_key
    session_key = Base.encode64("LEAKCHECKSECRET!")

    Fixtures.stub_code2session(%{
      wechat:
        Fixtures.code2session_body(:wechat, %{openid: "w-gql-leak", session_key: session_key})
    })

    # 路径 1：成功登录
    {encrypted_data, iv} =
      Fixtures.encrypt_phone(session_key, Fixtures.phone_payload("13800000022"))

    ok_conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-3", encrypted_data, iv))

    assert %{"data" => %{"signInWithPlatform" => %{"id" => _}}} = json_response(ok_conn, 200)
    refute ok_conn.resp_body =~ session_key, "成功响应体不得含 session_key"

    # 路径 2：解密失败（encryptedData 由另一个 key 加密）
    {bad_ed, bad_iv} =
      Fixtures.encrypt_phone(Fixtures.new_session_key(), Fixtures.phone_payload("13800000023"))

    err_conn =
      graphql_post(build_conn(), sign_in_mutation("wechat", "gql-code-4", bad_ed, bad_iv))

    assert %{"errors" => _} = json_response(err_conn, 200)
    refute err_conn.resp_body =~ session_key, "失败响应体不得含 session_key"
  end
end
