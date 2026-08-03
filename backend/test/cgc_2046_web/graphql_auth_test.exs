defmodule Cgc2046Web.GraphqlAuthTest do
  use Cgc2046Web.ConnCase, async: true

  @email "graphql@example.com"
  @password "sup3r-secret-password"

  defp graphql_post(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
  end

  defp graphql_response(conn) do
    json_response(conn, 200)
  end

  # ponytail: 复用 graphql_profile_test.exs:72 的正向范式——读 conn.resp_cookies，
  # 断言 before_send 写入了 httpOnly cgc_token。这是 GAP1 的正向 regression guard：
  # 误删 router 的 before_send 注册或改错 cookie 选项时此断言会失败。
  defp assert_auth_cookie_written(conn) do
    cookie = conn.resp_cookies["cgc_token"]
    assert cookie != nil, "expected cgc_token cookie to be written by before_send"
    assert cookie.http_only == true, "cgc_token must be httpOnly (防 JS 读取)"
    assert cookie.same_site == "Lax", "cgc_token sameSite 应为 Lax"
    assert is_binary(cookie.value) and byte_size(cookie.value) > 0, "cgc_token 值非空"
    # max_age 必须与 AshAuthentication token_lifetime（默认 14 天）对齐，
    # 否则 cookie 比 token 早过期 → 用户登录次日即被判定未登录（#5 regression guard）。
    assert cookie.max_age == 60 * 60 * 24 * 14,
           "cgc_token max_age 应为 14 天对齐 token_lifetime，实际 #{inspect(cookie.max_age)}"

    cookie
  end

  defp sign_up_query(email, password) do
    """
    mutation {
      signUp(input: { email: "#{email}", password: "#{password}" }) {
        result { id email isPlatformAdmin }
        errors { message }
      }
    }
    """
  end

  describe "signUp mutation" do
    test "registers a user and returns the user (token in httpOnly cookie)" do
      conn = build_conn()

      conn = graphql_post(conn, sign_up_query(@email, @password))
      res = graphql_response(conn)

      assert %{"data" => %{"signUp" => %{"result" => result}}} = res
      assert result["email"] == @email
      assert result["isPlatformAdmin"] == false
      # 正向 regression guard：before_send 必须写 httpOnly cgc_token。
      # 误删 router 的 before_send 注册或改错 cookie 选项时此断言失败。
      assert_auth_cookie_written(conn)
    end

    test "returns a validation error for a duplicate email" do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password)) |> graphql_response()

      res = graphql_post(conn, sign_up_query(@email, @password)) |> graphql_response()

      assert %{"data" => %{"signUp" => %{"errors" => errors}}} = res
      assert Enum.any?(errors, &(&1["message"] =~ "already been taken"))
    end

    test "rejects an invalid email format" do
      conn = build_conn()

      res = graphql_post(conn, sign_up_query("not-an-email", @password)) |> graphql_response()

      assert %{"data" => %{"signUp" => %{"result" => result, "errors" => errors}}} = res
      assert is_nil(result)
      assert Enum.any?(errors, &(&1["message"] =~ "email"))
    end
  end

  describe "signIn mutation" do
    setup do
      conn = build_conn()

      assert %{"data" => %{"signUp" => %{"result" => %{"id" => _id}}}} =
               graphql_post(conn, sign_up_query(@email, @password)) |> graphql_response()

      {:ok, conn: conn}
    end

    test "signs in with correct credentials and returns the user (token in httpOnly cookie)" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "#{@password}") {
          id
          email
          isPlatformAdmin
        }
      }
      """

      conn = graphql_post(build_conn(), query)
      res = graphql_response(conn)

      assert %{"data" => %{"signIn" => sign_in}} = res
      assert sign_in["email"] == @email
      assert sign_in["isPlatformAdmin"] == false
      # 正向 regression guard：before_send 必须写 httpOnly cgc_token
      assert_auth_cookie_written(conn)
    end

    test "returns an error for an invalid password" do
      query = """
      mutation {
        signIn(email: "#{@email}", password: "wrong-password") {
          id
          email
        }
      }
      """

      res = graphql_post(build_conn(), query) |> graphql_response()

      assert %{"data" => %{"signIn" => nil}, "errors" => errors} = res

      assert [%{"message" => "Invalid email or password", "code" => "authentication_failed"}] =
               errors
    end
  end

  describe "signOut mutation" do
    setup do
      conn = build_conn()
      conn = graphql_post(conn, sign_up_query(@email, @password))
      cookie = assert_auth_cookie_written(conn)
      {:ok, conn: conn, token: cookie.value}
    end

    test "clears the httpOnly auth cookie (登出后会话不残留)", %{token: token} do
      # 用登录拿到的 cookie 作为请求凭证，调 signOut
      conn =
        build_conn()
        |> put_req_cookie("cgc_token", token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "mutation { signOut }"})

      res = graphql_response(conn)
      assert %{"data" => %{"signOut" => "signed_out"}} = res

      # 正向 regression guard：signOut 的 middleware→before_send 链路必须清掉 cgc_token。
      # delete_resp_cookie 会写一个 max_age=0 的过期 Set-Cookie；Plug 把它收进 resp_cookies
      # 且 value 为空。若误删 cgc_clear_token 分支或 before_send，此断言失败。
      cleared = conn.resp_cookies["cgc_token"]
      assert cleared != nil, "signOut 后应下发清除 cgc_token 的 Set-Cookie"

      # delete_resp_cookie 写出的过期 cookie 形如 %{universal_time: ..., max_age: 0}，
      # 不带 :value。max_age: 0 即过期清除信号——这就是 regression guard 抓的目标。
      assert cleared[:max_age] == 0,
             "signOut 应把 cgc_token 设为 max_age=0 过期清除，实际 #{inspect(cleared)}"
    end

    test "revokes the token server-side (signOut 后旧 token 立即失效，不可重放)", %{token: token} do
      # 用登录拿到的 cookie 调 signOut
      sign_out_conn =
        build_conn()
        |> put_req_cookie("cgc_token", token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "mutation { signOut }"})

      assert %{"data" => %{"signOut" => "signed_out"}} = graphql_response(sign_out_conn)

      # 再用同一 token 打 me 查询——应判定未认证。
      # revoke 已把 tokens 表中该 jti 的记录 purpose 从 "user" upsert 成 "revocation"，
      # load_from_bearer 的 get_token 查 purpose: "user" 查不到 → user 不被 assign →
      # me resolver 读到 context[:actor] == nil → 返回 unauthorized。
      me_conn =
        build_conn()
        |> put_req_cookie("cgc_token", token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => "{ me { id email } }"})

      res = graphql_response(me_conn)

      assert %{"data" => %{"me" => nil}, "errors" => errors} = res

      assert Enum.any?(errors, &(&1["message"] == "unauthorized")),
             "signOut 后旧 token 应被服务端撤销，me 查询应返回 unauthorized，实际 #{inspect(res)}"
    end
  end
end
