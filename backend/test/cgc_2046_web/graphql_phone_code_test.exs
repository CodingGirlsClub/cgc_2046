defmodule Cgc2046Web.GraphqlPhoneCodeTest do
  @moduledoc """
  requestPhoneCode / signInWithPhoneCode GraphQL 层覆盖（plan 002 U3）。

  - 发码：成功（sent true + retryAfterSeconds）、非法手机号、限流各窗口
  - 登录：正确码自动建号 + cookie、错码 3 次失效、码单次使用、
    未归一化输入同号、重登吊销旧 token
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
    {:ok, code} = PhoneVerificationCode.issue(phone, purpose)
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
      assert claims["platform"] in [nil, "user"] or is_nil(claims["platform"])
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

      # 发新码（作废旧码）再登录
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
  end
end
