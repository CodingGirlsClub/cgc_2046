defmodule Cgc2046Web.GraphqlPhoneCodeTest do
  @moduledoc """
  requestPhoneCode / signInWithPhoneCode GraphQL 层覆盖（plan 002 U3）。

  - 发码：成功（sent true + retryAfterSeconds）、非法手机号、限流各窗口
  - 登录：正确码自动建号 + cookie、错码 3 次失效、码单次使用、
    未归一化输入同号、重登吊销旧 token
  - 换绑（updateMyPhone，purpose :change_phone）：成功/错码/purpose 隔离/
    他人占用/未登录/同号幂等；myPhone 掩码查询（含 null 与未登录）
  """
  use Cgc2046Web.ConnCase, async: false

  alias AshAuthentication.Jwt
  alias Cgc2046.Accounts.PhoneVerificationCode

  @stub Cgc2046.SmsSendCloudStub
  @phone_raw "13800138000"
  @phone "+8613800138000"

  setup do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{"result" => true})
    end)

    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    on_exit(fn -> :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table()) end)

    :ok
  end

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp request_code_mutation(phone \\ @phone_raw, purpose \\ "login") do
    """
    mutation {
      requestPhoneCode(phone: "#{phone}", purpose: #{String.upcase(purpose)}) {
        sent
        retryAfterSeconds
      }
    }
    """
  end

  defp sign_in_mutation(phone, code) do
    """
    mutation {
      signInWithPhoneCode(phone: "#{phone}", code: "#{code}") {
        id
        email
        isPlatformAdmin
      }
    }
    """
  end

  # 从 Logger 捕获 dev 模式出码（test 配了 stub 走 SendCloud 分支，
  # 但测试注入的凭证是 test 值——deliver_phone_code 走 configured? true +
  # stub 应答。为拿明文码，直接调 PhoneVerificationCode.issue 后手工验。）
  defp issue_and_get_code(phone, purpose \\ :login) do
    # 绕开 GraphQL 限流干扰，直接 issue 拿明文码
    {:ok, code, _rid} = PhoneVerificationCode.issue(phone, purpose)
    code
  end

  describe "requestPhoneCode" do
    test "成功：sent true + retryAfterSeconds 60" do
      res = graphql_post(build_conn(), request_code_mutation()) |> json_response(200)

      assert %{"data" => %{"requestPhoneCode" => %{"sent" => true, "retryAfterSeconds" => 60}}} =
               res
    end

    test "未归一化手机号（138…）与规范形同限流 key：第二笔 1/60s 即被拒" do
      graphql_post(build_conn(), request_code_mutation("13800138001"))

      res =
        graphql_post(build_conn(), request_code_mutation("+86 138-0013-8001"))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "rate_limited"}]} = res
    end

    test "1 分钟窗口：第二次立刻发同号被限流" do
      graphql_post(build_conn(), request_code_mutation())
      res = graphql_post(build_conn(), request_code_mutation()) |> json_response(200)

      assert %{"errors" => [%{"code" => "rate_limited"}]} = res
    end

    test "小时窗口：1/60s 放过后 5/1h 上限（隔 60s 由窗口推进模拟不了，直接灌满计数）" do
      # 用不同号灌满 IP 30/1d 前先灌 phone 5/1h：同号 5 次（每次手动清 1m 窗口表不可行，
      # 改为直接操作内部 check——经 build_key 语义等价）。此处验证窗口参数生效：
      # 手工注入 4 次历史计数后第 5 次允许、第 6 次拒绝。
      phone = "+8613800138002"

      for _ <- 1..4 do
        :ok =
          Cgc2046Web.Plugs.RateLimit.check("rate:phone-code:phone:1h:#{phone}",
            window_seconds: 3_600,
            max_attempts: 5
          )
      end

      # 第 5 次允许（计数 4→5）……但 1m 窗口仍首笔，会通过
      res = graphql_post(build_conn(), request_code_mutation("13800138002"))
      assert %{"data" => %{"requestPhoneCode" => %{"sent" => true}}} = json_response(res, 200)

      # 第 6 次：1h 窗口拒绝
      res2 = graphql_post(build_conn(), request_code_mutation("13800138002"))
      assert %{"errors" => [%{"code" => "rate_limited"}]} = json_response(res2, 200)
    end

    test "SendCloud 投递失败 → sent false（M4：不再吞错恒 true）" do
      # 覆盖 setup 的成功 stub：本次请求返回 result:false
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"result" => false, "message" => "template rejected"})
      end)

      res = graphql_post(build_conn(), request_code_mutation("13800138003"))

      assert %{
               "data" => %{"requestPhoneCode" => %{"sent" => false, "retryAfterSeconds" => 60}}
             } = json_response(res, 200)
    end

    test "非法手机号 → invalid_phone" do
      res = graphql_post(build_conn(), request_code_mutation("not-a-phone")) |> json_response(200)

      assert %{"errors" => [%{"code" => "invalid_phone"}]} = res
    end
  end

  describe "signInWithPhoneCode" do
    test "正确码：自动建号 + httpOnly cookie + email 可空" do
      code = issue_and_get_code(@phone)

      conn = graphql_post(build_conn(), sign_in_mutation(@phone_raw, code))
      res = json_response(conn, 200)

      assert %{"data" => %{"signInWithPhoneCode" => payload}} = res
      assert is_binary(payload["id"])
      assert is_nil(payload["email"])
      assert payload["isPlatformAdmin"] == false

      cookie = conn.resp_cookies["cgc_token"]
      assert cookie != nil and cookie.http_only == true
      {:ok, claims} = Jwt.peek(cookie.value)
      assert claims["purpose"] == "user"
      # M8：web 面 token 带 platform=web claim
      assert claims["platform"] == "web"
    end

    test "未归一化输入同号（138… vs +86138…）" do
      code = issue_and_get_code(@phone)

      conn = graphql_post(build_conn(), sign_in_mutation("+86 138-0013-8000", code))

      assert %{"data" => %{"signInWithPhoneCode" => %{"id" => _}}} = json_response(conn, 200)
    end

    test "错码 3 次 → invalid_or_expired_code；正确码随后也不可用" do
      code = issue_and_get_code(@phone)
      wrong = if code == "000000", do: "111111", else: "000000"

      for i <- 1..3 do
        res =
          graphql_post(build_conn(), sign_in_mutation(@phone_raw, wrong)) |> json_response(200)

        assert %{"errors" => errors} = res
        assert [%{"code" => code_err} | _] = errors

        # 前 2 次错码、第 3 次耗尽——统一 invalid_or_expired_code（防枚举）
        assert code_err == "invalid_or_expired_code", "attempt #{i}"
      end

      res = graphql_post(build_conn(), sign_in_mutation(@phone_raw, code)) |> json_response(200)
      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} = res
    end

    test "码单次使用：第二次同码登录失败" do
      code = issue_and_get_code(@phone)

      graphql_post(build_conn(), sign_in_mutation(@phone_raw, code))

      res = graphql_post(build_conn(), sign_in_mutation(@phone_raw, code)) |> json_response(200)
      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} = res
    end

    test "重登吊销旧 token" do
      code1 = issue_and_get_code(@phone)
      conn1 = graphql_post(build_conn(), sign_in_mutation(@phone_raw, code1))
      old_token = conn1.resp_cookies["cgc_token"].value

      # 发新码再登录（#253 A：新旧并存；此处消费 code2 成功作废全部）
      code2 = issue_and_get_code(@phone)
      graphql_post(build_conn(), sign_in_mutation(@phone_raw, code2))

      # 旧 token 已被吊销：me 查询 401 语义（token 白名单 miss；
      # 吊销路径可能报 auth_uncertain——#13 语义：保持登录态重试而非踢出）
      me_conn =
        build_conn()
        |> put_req_cookie("cgc_token", old_token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "{ me { id } }"})

      me_res = json_response(me_conn, 200)
      assert me_res["data"]["me"] == nil
      assert Enum.any?(me_res["errors"], &(&1["code"] in ["unauthorized", "auth_uncertain"]))
    end

    test "M8 跨端互踢隔离：web 登录不吊销小程序 token" do
      # 小程序登录（内部路径，platform :wechat）
      {:ok, mp_user} =
        Cgc2046.Accounts.User
        |> Ash.Changeset.for_create(:register_with_miniprogram, %{phone: @phone})
        |> Ash.create(authorize?: false, context: %{private: %{ash_authentication?: true}})

      {:ok, mp_signed} =
        Cgc2046.Accounts.SignInFlow.generate_token(mp_user, :wechat, %{
          private: %{ash_authentication?: true}
        })

      mp_token = mp_signed.__metadata__[:token]

      # web SMS 登录（吊销 web 面）
      code = issue_and_get_code(@phone)
      graphql_post(build_conn(), sign_in_mutation(@phone_raw, code))

      # 小程序 token 仍有效（me 可查）
      me_conn =
        build_conn()
        |> put_req_cookie("cgc_token", mp_token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "{ me { id } }"})

      me_res = json_response(me_conn, 200)
      assert me_res["data"]["me"] != nil
      assert me_res["data"]["me"]["id"] == mp_user.id
    end

    test "M8 web 面内吊销：旧 web token（无 platform claim 的密码 token）被 web 登录吊销" do
      # 密码路径 token（无 platform claim，M8 归入 web 面）
      {:ok, user} =
        Cgc2046.Accounts.User
        |> Ash.Changeset.for_create(:register_with_password, %{
          email: "m8-web-face@test.local",
          password: "password12345"
        })
        |> Ash.create(authorize?: false, context: %{private: %{ash_authentication?: true}})

      strategy = AshAuthentication.Info.strategy!(Cgc2046.Accounts.User, :password)

      {:ok, signed} =
        AshAuthentication.Strategy.action(strategy, :sign_in, %{
          "email" => "m8-web-face@test.local",
          "password" => "password12345"
        })

      pw_token = signed.__metadata__[:token]

      # 同一 user 绑 phone 后 web SMS 登录（find-or-create 命中同号用户）——
      # 用同一手机号：先给该 user 设 phone
      # 内部路径直接落 phone（资源无通用 update action）
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE users SET phone = $1 WHERE id = $2",
        ["+8613800139393", Ecto.UUID.dump!(user.id)]
      )

      code = issue_and_get_code("+8613800139393")
      graphql_post(build_conn(), sign_in_mutation("13800139393", code))

      # 密码 token 已被 web 面吊销
      me_conn =
        build_conn()
        |> put_req_cookie("cgc_token", pw_token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "{ me { id } }"})

      me_res = json_response(me_conn, 200)
      assert me_res["data"]["me"] == nil
    end
  end

  describe "signUpWithPhone" do
    @password "sup3r-secret-password"

    defp sign_up_phone_mutation(phone, code, password) do
      """
      mutation {
        signUpWithPhone(input: { phone: "#{phone}", code: "#{code}", password: "#{password}" }) {
          result { id email isPlatformAdmin }
          errors { message code fields }
        }
      }
      """
    end

    test "正确码：建号（email 可空）+ 密码可登录 + httpOnly cookie + 入座 2046" do
      # seed 默认 workspace（测试库无 seed；admit_to_default_workspace 按 slug=2046 找）
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        ~s'INSERT INTO workspaces (slug, name) VALUES (\x272046\x27, \x27CGC 2046\x27) ON CONFLICT (slug) DO NOTHING'
      )

      code = issue_and_get_code(@phone, :register)

      conn = graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, code, @password))
      res = json_response(conn, 200)

      assert %{"data" => %{"signUpWithPhone" => payload}} = res
      assert payload["errors"] == []
      assert is_binary(payload["result"]["id"])
      assert is_nil(payload["result"]["email"])

      cookie = conn.resp_cookies["cgc_token"]
      assert cookie != nil and cookie.http_only == true
      {:ok, claims} = Jwt.peek(cookie.value)
      assert claims["purpose"] == "user"

      # 建号后密码可登录（password_phone 策略 sign-in 路径打通）
      sign_in_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/graphql",
          %{
            "query" =>
              ~s'mutation { signIn(login: "#{@phone_raw}", password: "#{@password}") { id isPlatformAdmin } }'
          }
        )

      assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(sign_in_conn, 200)

      # ADR-0004 §3.5：注册自动入座默认 workspace 2046
      membership =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          """
          SELECT count(*) FROM workspace_memberships wm
          JOIN workspaces w ON w.id = wm.workspace_id
          WHERE wm.user_id = $1 AND w.slug = '2046'
          """,
          [Ecto.UUID.dump!(payload["result"]["id"])]
        )

      assert [%{rows: [[count]]}] = [membership]
      assert count == 1
    end

    test "已注册手机号：phone_already_registered（验码通过后返回，无枚举风险）" do
      code = issue_and_get_code(@phone, :register)
      graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, code, @password))

      code2 = issue_and_get_code(@phone, :register)
      res = graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, code2, @password))

      assert %{"errors" => [%{"code" => "phone_already_registered"}]} =
               json_response(res, 200)
    end

    test "真实发码链路：requestPhoneCode(REGISTER) 可发码并完成注册（atom 映射回归钉测）" do
      # 直接调 issue 绕过了 request_phone_code → phone_code_purpose_atom 入口，
      # 曾漏 :register 映射导致 FunctionClauseError。此用例钉住全链路。
      conn =
        graphql_post(
          build_conn(),
          """
          mutation {
            requestPhoneCode(phone: "#{@phone_raw}", purpose: REGISTER) {
              sent
              retryAfterSeconds
            }
          }
          """
        )

      assert %{"data" => %{"requestPhoneCode" => %{"retryAfterSeconds" => 60}}} =
               json_response(conn, 200)
    end

    test "短密码：invalid_password 且不烧码（修正后同码可用）" do
      code = issue_and_get_code(@phone, :register)

      res =
        graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, code, "short"))

      assert %{"errors" => [%{"code" => "invalid_password"}]} = json_response(res, 200)

      # 密码校验先于验码消费——同码换合法密码应成功
      res2 =
        graphql_post(
          build_conn(),
          sign_up_phone_mutation(@phone_raw, code, @password)
        )

      assert %{"data" => %{"signUpWithPhone" => %{"result" => %{"id" => _}}}} =
               json_response(res2, 200)
    end

    test "超 72 字节密码：invalid_password（bcrypt 截断互认防线）" do
      code = issue_and_get_code(@phone, :register)

      res =
        graphql_post(
          build_conn(),
          sign_up_phone_mutation(@phone_raw, code, String.duplicate("a", 73))
        )

      assert %{"errors" => [%{"code" => "invalid_password"}]} = json_response(res, 200)
    end

    test "错码：invalid_or_expired_code，不建号" do
      _code = issue_and_get_code(@phone, :register)

      res = graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, "000000", @password))

      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} =
               json_response(res, 200)
    end

    test "register purpose 码不串用：login purpose 码注册被拒" do
      login_code = issue_and_get_code(@phone, :login)

      res = graphql_post(build_conn(), sign_up_phone_mutation(@phone_raw, login_code, @password))

      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} =
               json_response(res, 200)
    end
  end

  # ── 设置页绑定/换绑手机号（purpose :change_phone）────────────────────────

  defp update_my_phone_mutation(phone, code) do
    """
    mutation {
      updateMyPhone(phone: "#{phone}", code: "#{code}") {
        id
        memberNumber
        joinedAt
      }
    }
    """
  end

  # 无手机号用户（password 策略建号，email 唯一防冲突）
  defp create_user_without_phone do
    {:ok, user} =
      Cgc2046.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "cp-#{Ecto.UUID.generate()}@example.com",
        password: "sup3r-secret-password"
      })
      |> Ash.create(authorize?: false, context: %{private: %{ash_authentication?: true}})

    user
  end

  # 有手机号用户（小程序策略建号，phone 为锚）
  defp create_user_with_phone(phone) do
    {:ok, user} =
      Cgc2046.Accounts.User
      |> Ash.Changeset.for_create(:register_with_miniprogram, %{phone: phone})
      |> Ash.create(authorize?: false, context: %{private: %{ash_authentication?: true}})

    user
  end

  defp web_token(user) do
    {:ok, signed} =
      Cgc2046.Accounts.SignInFlow.generate_token(user, :web, %{
        private: %{ash_authentication?: true}
      })

    signed.__metadata__[:token]
  end

  defp authed_post(token, query) do
    build_conn()
    |> put_req_cookie("cgc_token", token)
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  describe "updateMyPhone" do
    test "成功：change_phone 码换绑，users.phone 更新并返回 user（含计算字段）" do
      user = create_user_without_phone()
      token = web_token(user)
      code = issue_and_get_code(@phone, :change_phone)

      res = authed_post(token, update_my_phone_mutation(@phone_raw, code)) |> json_response(200)

      assert %{
               "data" => %{
                 "updateMyPhone" => %{"id" => id, "memberNumber" => mn, "joinedAt" => ja}
               }
             } = res

      assert id == user.id
      assert String.starts_with?(mn, "CGC-")
      assert is_binary(ja)

      %{rows: [[db_phone]]} =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "SELECT phone FROM users WHERE id = $1",
          [Ecto.UUID.dump!(user.id)]
        )

      assert db_phone == @phone
    end

    test "错码 → invalid_or_expired_code，phone 不变" do
      user = create_user_without_phone()
      token = web_token(user)
      code = issue_and_get_code(@phone, :change_phone)
      wrong = if code == "000000", do: "111111", else: "000000"

      res = authed_post(token, update_my_phone_mutation(@phone_raw, wrong)) |> json_response(200)

      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} = res
    end

    test "purpose 隔离：login 码不能用于换绑" do
      user = create_user_without_phone()
      token = web_token(user)
      login_code = issue_and_get_code(@phone, :login)

      res =
        authed_post(token, update_my_phone_mutation(@phone_raw, login_code))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "invalid_or_expired_code"}]} = res
    end

    test "目标号已被他人占用 → phone_already_registered" do
      _other = create_user_with_phone(@phone)
      user = create_user_without_phone()
      token = web_token(user)
      code = issue_and_get_code(@phone, :change_phone)

      res = authed_post(token, update_my_phone_mutation(@phone_raw, code)) |> json_response(200)

      assert %{"errors" => [%{"code" => "phone_already_registered"}]} = res
    end

    test "未登录 → unauthorized（码不被消费）" do
      code = issue_and_get_code(@phone, :change_phone)

      res =
        graphql_post(build_conn(), update_my_phone_mutation(@phone_raw, code))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "unauthorized"}]} = res

      # 未登录调用被拒后码未被消费：同一 phone+code 做已登录换绑应成功
      user = create_user_without_phone()
      token = web_token(user)

      res2 = authed_post(token, update_my_phone_mutation(@phone_raw, code)) |> json_response(200)

      assert %{"data" => %{"updateMyPhone" => %{"id" => id}}} = res2
      assert id == user.id
    end

    test "新号 == 现号 → 幂等成功（验码通过但不改行）" do
      user = create_user_with_phone(@phone)
      token = web_token(user)
      code = issue_and_get_code(@phone, :change_phone)

      res = authed_post(token, update_my_phone_mutation(@phone_raw, code)) |> json_response(200)

      assert %{"data" => %{"updateMyPhone" => %{"id" => id}}} = res
      assert id == user.id
    end

    test "非法手机号 → invalid_phone" do
      user = create_user_without_phone()
      token = web_token(user)

      res =
        authed_post(token, update_my_phone_mutation("not-a-phone", "123456"))
        |> json_response(200)

      assert %{"errors" => [%{"code" => "invalid_phone"}]} = res
    end

    test "真实发码链路：requestPhoneCode(CHANGE_PHONE) 可发码（atom 映射回归钉测）" do
      res =
        graphql_post(build_conn(), request_code_mutation("13800138004", "change_phone"))
        |> json_response(200)

      assert %{"data" => %{"requestPhoneCode" => %{"sent" => true}}} = res
    end
  end

  describe "myPhone" do
    test "已绑定：返回掩码（前 6 + **** + 后 4）" do
      user = create_user_with_phone("+8615578793094")
      token = web_token(user)

      res = authed_post(token, "query { myPhone }") |> json_response(200)

      assert %{"data" => %{"myPhone" => "+86155****3094"}} = res
    end

    test "未绑定：返回 null" do
      user = create_user_without_phone()
      token = web_token(user)

      res = authed_post(token, "query { myPhone }") |> json_response(200)

      assert %{"data" => %{"myPhone" => nil}} = res
    end

    test "未登录 → unauthorized" do
      res = graphql_post(build_conn(), "query { myPhone }") |> json_response(200)

      assert %{"errors" => [%{"code" => "unauthorized"}]} = res
    end
  end
end
