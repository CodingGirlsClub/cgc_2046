defmodule Cgc2046Web.GraphqlSetPasswordTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.{SignInFlow, User}

  @phone "13900001111"
  @password "sup3r-secret-password"

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp graphql_response(conn), do: json_response(conn, 200)

  # 小程序建号用户：phone 有、email 与密码哈希都为空
  defp create_phone_user do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:register_with_miniprogram, %{phone: @phone})
      |> Ash.create(authorize?: false)

    user
  end

  defp issue_token(user) do
    {:ok, signed} = SignInFlow.generate_token(user, nil, %{})
    signed.__metadata__[:token]
  end

  describe "setPassword" do
    test "sets a password for a phone-only account and refreshes the current session" do
      user = create_phone_user()
      old_token = issue_token(user)

      query = ~s'mutation { setPassword(password: "#{@password}") { ok } }'

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> graphql_post(query)

      res = graphql_response(conn)
      assert %{"data" => %{"setPassword" => %{"ok" => true}}} = res

      # 当前会话换发新 token：cookie 写入新值
      cookie = conn.resp_cookies["cgc_token"]
      assert cookie != nil
      assert cookie.value != old_token

      # 旧 token 已被吊销：再拿它读 me 不再返回该用户
      stale =
        build_conn()
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> graphql_post(~s'query { me { id } }')
        |> graphql_response()

      refute get_in(stale, ["data", "me", "id"]) == user.id

      # 手机号 + 新密码可登录（Web/Desktop 的消费路径）
      sign_in =
        build_conn()
        |> graphql_post(
          ~s'mutation { signIn(login: "#{@phone}", password: "#{@password}") { id } }'
        )
        |> graphql_response()

      assert %{"data" => %{"signIn" => %{"id" => id}}} = sign_in
      assert id == user.id
    end

    test "rejects a password shorter than eight characters" do
      user = create_phone_user()
      token = issue_token(user)

      res =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> graphql_post(~s'mutation { setPassword(password: "short") { ok } }')
        |> graphql_response()

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, fn error -> is_binary(error["message"]) end)
    end

    test "requires an authenticated caller" do
      res =
        build_conn()
        |> graphql_post(~s'mutation { setPassword(password: "#{@password}") { ok } }')
        |> graphql_response()

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["code"] == "unauthorized"))
    end
  end
end
