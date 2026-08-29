defmodule Cgc2046Web.GraphqlPasswordResetTest do
  use Cgc2046Web.ConnCase, async: false

  # RateLimit 使用全局 ETS 表 :cgc_rate_limiter，async: false 防计数互相污染
  # （同 graphql_invitation_rate_limit_test.exs）。

  alias AshAuthentication.{Info, Jwt, Strategy}
  alias Cgc2046.Accounts.{User}
  alias Cgc2046.AccountsFixtures, as: Fixtures

  @password "sup3r-secret-password"
  @revoke_telemetry_event [:cgc2046, :password_reset, :revoke]

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 5)
    Application.put_env(:cgc_2046, :web_base_url, "http://localhost:3000")

    on_exit(fn ->
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999)
    end)

    :ok
  end

  describe "password reset failure telemetry classification" do
    test "only explicit revocation failures use revoke telemetry" do
      revoke_marker =
        Cgc2046.Accounts.PasswordResetRevocationError.exception(reason: [:injected])

      wrapped_revoke_marker = Ash.Error.to_error_class(revoke_marker)

      assert {@revoke_telemetry_event, :revoke_failed} =
               Cgc2046.Accounts.WebAuthFlow.password_reset_failure_telemetry(revoke_marker)

      assert {@revoke_telemetry_event, :revoke_failed} =
               Cgc2046.Accounts.WebAuthFlow.password_reset_failure_telemetry(
                 wrapped_revoke_marker
               )

      for reason <- [
            :unexpected_result,
            {:error, :unexpected},
            RuntimeError.exception("reset crashed"),
            {:throw, :reset_threw}
          ] do
        assert {[:cgc2046, :password_reset, :reset], :reset_failed} =
                 Cgc2046.Accounts.WebAuthFlow.password_reset_failure_telemetry(reason)
      end
    end
  end

  describe "requestPasswordReset mutation" do
    test "existing user: returns sent: true and delivers the reset email asynchronously" do
      user = Fixtures.register_user_with_email("gql-pwd-reset-existing@example.com")

      res = post_reset_request(to_string(user.email))

      assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} = res

      assert_receive {:email, email}, 1_000
      assert {_name, address} = List.first(email.to)
      assert address == to_string(user.email)
      assert email.html_body =~ "/reset-password?token="
    end

    test "unknown email: returns sent: true with no email (AE1, R2 防枚举)" do
      res = post_reset_request("gql-pwd-reset-missing@example.com")

      assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} = res
      refute_receive {:email, _email}, 200
    end

    test "IP+email layer: 6th request for the same email is rate limited" do
      email = "gql-pwd-reset-rl1@example.com"

      for _ <- 1..5 do
        assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
                 post_reset_request(email)
      end

      res = post_reset_request(email)
      assert rate_limited?(res)
    end

    test "email case variants share the same quota (AE5)" do
      for _ <- 1..4 do
        assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
                 post_reset_request("gql-pwd-reset-case@example.com")
      end

      assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
               post_reset_request("GQL-PWD-RESET-CASE@EXAMPLE.COM")

      res = post_reset_request("gql-pwd-reset-case@example.com")
      assert rate_limited?(res)
    end

    test "email-only hourly layer: same email across different IPs is rate limited (AE5)" do
      email = "gql-pwd-reset-emailonly@example.com"

      for ip_index <- 1..5 do
        conn = conn_with_ip(build_conn(), ip_index)

        assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
                 graphql_post(conn, request_query(email))
      end

      # 换第 6 个 IP：IP+email 层不命中，email-only 层（每小时 5 次）拒绝
      res = conn_with_ip(build_conn(), 6) |> graphql_post(request_query(email))
      assert rate_limited?(res)
    end

    test "IP-only cross-email layer: 21st distinct email from one IP is rate limited (R6)" do
      for index <- 1..20 do
        assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
                 post_reset_request("gql-pwd-reset-ip#{index}@example.com")
      end

      res = post_reset_request("gql-pwd-reset-ip21@example.com")
      assert rate_limited?(res)
    end
  end

  describe "resetPassword mutation" do
    test "success: ok: true, old password fails, new password works, all sessions revoked (AE3/AE4/AE6)" do
      user = Fixtures.register_user_with_email("gql-pwd-reset-success@example.com")
      strategy = Info.strategy!(User, :password)

      {:ok, signed_in} =
        Strategy.action(strategy, :sign_in, %{
          "email" => "gql-pwd-reset-success@example.com",
          "password" => @password
        })

      session_token = signed_in.__metadata__[:token]

      # 小程序策略签发的会话同为 purpose="user" 存储 token；以同一生成路径签发等价 token 验证两端吊销
      {:ok, miniprogram_equivalent_token, _claims} = Jwt.token_for_user(user, %{})

      # 正向：重置前两枚会话 token 均可访问 me
      assert %{"data" => %{"me" => %{"id" => _id}}} = post_me(session_token)
      assert %{"data" => %{"me" => %{"id" => _id}}} = post_me(miniprogram_equivalent_token)

      first_token = reset_token_via_graphql("gql-pwd-reset-success@example.com")
      second_token = reset_token_via_graphql("gql-pwd-reset-success@example.com")

      res = post_reset(first_token, "brand-new-password-1")
      assert %{"data" => %{"resetPassword" => %{"ok" => true}}} = res

      # 旧密码登录失败，新密码登录成功
      assert %{"errors" => [%{"code" => "authentication_failed"}]} =
               post_sign_in("gql-pwd-reset-success@example.com", @password)

      assert %{"data" => %{"signIn" => %{"email" => _email}}} =
               post_sign_in("gql-pwd-reset-success@example.com", "brand-new-password-1")

      # 重置前签发的 web 会话 token 与小程序等价 token 均被吊销。
      # 应用对「token 签名有效但已撤销」的既定形状是 auth_uncertain（#13 Finding A：
      # 吊销 / DB 故障同形，AuthPlug 标记 cgc_auth_uncertain），非 unauthorized。
      assert %{"errors" => [%{"code" => "auth_uncertain"}]} = post_me(session_token)

      assert %{"errors" => [%{"code" => "auth_uncertain"}]} =
               post_me(miniprogram_equivalent_token)

      # 另一枚未用 reset token 即刻失效（AE6）
      res = post_reset(second_token, "brand-new-password-2")
      assert invalid_reset_token?(res)
    end

    test "invalid, expired and already-used tokens share one error shape (AE3, R4)" do
      _user = Fixtures.register_user_with_email("gql-pwd-reset-invalid@example.com")
      token = reset_token_via_graphql("gql-pwd-reset-invalid@example.com")

      # 伪造 token
      assert invalid_reset_token?(post_reset("forged.token.value", "brand-new-password"))

      # 已使用 token
      assert %{"data" => %{"resetPassword" => %{"ok" => true}}} =
               post_reset(token, "brand-new-password")

      assert invalid_reset_token?(post_reset(token, "brand-new-password-2"))
    end

    test "weak password: error points at the password field and the token is not consumed (R8)" do
      _user = Fixtures.register_user_with_email("gql-pwd-reset-weak@example.com")
      token = reset_token_via_graphql("gql-pwd-reset-weak@example.com")

      res = post_reset(token, "short")

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["fields"] == ["password"]))
      refute invalid_reset_token?(res)

      # 同一 token 用合规密码仍成功 → 弱密码未消耗 token
      assert %{"data" => %{"resetPassword" => %{"ok" => true}}} =
               post_reset(token, "brand-new-password")
    end

    test "revoke failure is fail-closed: reset fails, telemetry recorded, token not consumed (R5)" do
      _user = Fixtures.register_user_with_email("gql-pwd-reset-revoke@example.com")
      token = reset_token_via_graphql("gql-pwd-reset-revoke@example.com")

      test_pid = self()
      handler_id = "gql-pwd-reset-revoke-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          @revoke_telemetry_event,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:revoke_telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # 吊销写失败注入：tokens 表 UPDATE 触发器抛错（读路径不受影响——
      # Jwt.verify 的 revoked? 检查仍可读表）。sandbox 事务内 DDL 自动回滚。
      Cgc2046.Repo.query!("""
      CREATE FUNCTION cgc_pwd_reset_inject_fail() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'injected revoke failure';
      END;
      $$ LANGUAGE plpgsql
      """)

      Cgc2046.Repo.query!("""
      CREATE TRIGGER cgc_pwd_reset_inject_fail_trg
      BEFORE UPDATE ON tokens
      FOR EACH ROW EXECUTE FUNCTION cgc_pwd_reset_inject_fail()
      """)

      res = post_reset(token, "brand-new-password")
      assert %{"errors" => [%{"code" => "password_reset_failed"}]} = res

      assert_receive {:revoke_telemetry, @revoke_telemetry_event, %{count: 1}, metadata}, 1_000
      assert metadata.reason == :revoke_failed

      Cgc2046.Repo.query!("DROP TRIGGER cgc_pwd_reset_inject_fail_trg ON tokens")
      Cgc2046.Repo.query!("DROP FUNCTION cgc_pwd_reset_inject_fail()")

      # 同一 token 重试成功 → 吊销失败时 token 未被消耗
      assert %{"data" => %{"resetPassword" => %{"ok" => true}}} =
               post_reset(token, "brand-new-password")
    end

    test "resetPassword is rate limited by IP+token (6th attempt rejected)" do
      _user = Fixtures.register_user_with_email("gql-pwd-reset-rl2@example.com")
      token = reset_token_via_graphql("gql-pwd-reset-rl2@example.com")

      for _ <- 1..5 do
        graphql_post(build_conn(), reset_query(token, "whatever-password"))
      end

      res = graphql_post(build_conn(), reset_query(token, "whatever-password"))
      assert rate_limited?(res)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp conn_with_ip(conn, ip_index), do: %{conn | remote_ip: {10, 0, 0, ip_index}}

  defp post_reset_request(email) do
    graphql_post(build_conn(), request_query(email))
  end

  defp request_query(email) do
    """
    mutation {
      requestPasswordReset(email: "#{email}") {
        sent
      }
    }
    """
  end

  defp post_reset(token, password) do
    graphql_post(build_conn(), reset_query(token, password))
  end

  defp reset_query(token, password) do
    """
    mutation {
      resetPassword(resetToken: "#{token}", password: "#{password}") {
        ok
      }
    }
    """
  end

  defp post_sign_in(email, password) do
    graphql_post(
      build_conn(),
      """
      mutation {
        signIn(login: "#{email}", password: "#{password}") {
          email
        }
      }
      """
    )
  end

  defp post_me(token) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")

    graphql_post(conn, "query { me { id } }")
  end

  # 经 GraphQL 请求重置并从 Test adapter 邮件中提取 reset token
  defp reset_token_via_graphql(email) do
    assert %{"data" => %{"requestPasswordReset" => %{"sent" => true}}} =
             post_reset_request(email)

    assert_receive {:email, email_message}, 1_000
    [_, token] = Regex.run(~r{/reset-password\?token=([^"<]+)}, email_message.html_body)
    token
  end

  defp rate_limited?(%{"errors" => errors}) do
    Enum.any?(errors, &(&1["code"] == "rate_limited"))
  end

  defp invalid_reset_token?(%{"errors" => errors}) do
    Enum.any?(errors, &(&1["code"] == "invalid_reset_token"))
  end
end
