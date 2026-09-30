defmodule Cgc2046Web.GraphqlWechatMiniWebLoginTest do
  use Cgc2046Web.ConnCase, async: false
  alias Cgc2046.Accounts.{SignInFlow, User, UserIdentity}
  @internal [context: %{private: %{ash_authentication?: true}}]
  @start "mutation { wechatMiniWebLoginStart(mode: QR) { requestId status expiresAt qrDataUrl } }"

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())

    Req.Test.stub(Cgc2046.MiniprogramClientStub, fn conn ->
      assert conn.request_path == "/wxa/getwxacodeunlimit"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["page"] == "pages/web-login/index"
      assert body["check_path"] == true
      assert body["env_version"] == "release"
      assert String.starts_with?(body["scene"], "wl_")

      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    end)

    :ok
  end

  defp http(query, cookies \\ %{}, token \\ nil, origin \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")

    conn =
      put_req_header(conn, "origin", origin || Application.fetch_env!(:cgc_2046, :web_base_url))

    conn = Enum.reduce(cookies, conn, fn {key, value}, c -> put_req_cookie(c, key, value) end)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, "/api/graphql", %{"query" => query})
  end

  defp begin_login do
    conn = http(@start)
    body = json_response(conn, 200)
    refute body["errors"], inspect(body)
    data = body["data"]["wechatMiniWebLoginStart"]
    proof = conn.resp_cookies["cgc_mp_web_proof"].value
    assert proof != data["requestId"]
    assert conn.resp_cookies["cgc_mp_web_proof"].http_only
    {data["requestId"], %{"cgc_mp_web_proof" => proof}}
  end

  defp account(platform \\ :wechat) do
    phone = "+86138" <> String.pad_leading(to_string(System.unique_integer([:positive])), 8, "0")
    {:ok, user, true} = SignInFlow.find_or_create_user(phone)

    Ash.create!(
      UserIdentity,
      %{provider: platform, uid: Ecto.UUID.generate(), user_id: user.id},
      Keyword.put(@internal, :action, :upsert)
    )

    {:ok, signed} = SignInFlow.generate_token(user, platform, %{})
    {user, signed.__metadata__.token}
  end

  defp operation(name, id), do: "mutation { #{name}(requestId: \"#{id}\") { status id } }"

  defp status(id),
    do: "{ wechatMiniWebLoginStatus(requestId: \"#{id}\") { status sessionEstablished } }"

  defp assert_error(conn, code) do
    body = json_response(conn, 200)

    assert Enum.any?(
             body["errors"] || [],
             &(&1["code"] == code || get_in(&1, ["extensions", "code"]) == code)
           ),
           inspect(body)

    refute Map.has_key?(conn.resp_cookies, "cgc_token")
  end

  test "explicit confirmation then original browser consumption; mini token survives and response recovery is bound to jti" do
    {user, token} = account()
    {id, cookies} = begin_login()

    assert_error(
      http(operation("wechatMiniWebLoginConsume", id), cookies),
      "mini_web_login_not_approved"
    )

    confirmed = http(operation("wechatMiniWebLoginConfirm", id), %{}, token)

    assert get_in(json_response(confirmed, 200), ["data", "wechatMiniWebLoginConfirm", "status"]) ==
             "APPROVED"

    refute Map.has_key?(confirmed.resp_cookies, "cgc_token")
    consumed = http(operation("wechatMiniWebLoginConsume", id), cookies)

    assert get_in(json_response(consumed, 200), ["data", "wechatMiniWebLoginConsume", "id"]) ==
             user.id

    web_token = consumed.resp_cookies["cgc_token"].value
    recovery = http(status(id), Map.put(cookies, "cgc_token", web_token)) |> json_response(200)
    assert recovery["data"]["wechatMiniWebLoginStatus"]["sessionEstablished"]
    lost = http(status(id), cookies) |> json_response(200)
    refute lost["data"]["wechatMiniWebLoginStatus"]["sessionEstablished"]

    assert get_in(http("{ me { id } }", %{}, token) |> json_response(200), ["data", "me", "id"]) ==
             user.id

    assert_error(
      http(operation("wechatMiniWebLoginConsume", id), cookies),
      "mini_web_login_consumed"
    )
  end

  test "public code and a different browser cannot query, cancel or consume" do
    {_user, token} = account()
    {id, _cookies} = begin_login()
    http(operation("wechatMiniWebLoginConfirm", id), %{}, token)

    for cookies <- [%{}, %{"cgc_mp_web_proof" => String.duplicate("a", 43)}],
        query <- [
          status(id),
          operation("wechatMiniWebLoginConsume", id),
          operation("wechatMiniWebLoginCancel", id)
        ] do
      assert_error(http(query, cookies), "mini_web_login_invalid")
    end
  end

  test "anonymous and non-WeChat actors cannot confirm" do
    {_user, xhs_token} = account(:xhs)
    {id, _} = begin_login()

    for token <- [nil, xhs_token] do
      assert_error(
        http(operation("wechatMiniWebLoginConfirm", id), %{}, token),
        "mini_web_login_invalid"
      )
    end
  end

  test "confirmation is immutable and same actor retry is idempotent" do
    {_, first} = account()
    {_, second} = account()
    {id, _} = begin_login()

    for _ <- 1..2 do
      conn = http(operation("wechatMiniWebLoginConfirm", id), %{}, first)
      refute json_response(conn, 200)["errors"]
    end

    assert_error(
      http(operation("wechatMiniWebLoginConfirm", id), %{}, second),
      "mini_web_login_account_conflict"
    )
  end

  test "cancelled and expired requests cannot be confirmed" do
    {_, token} = account()
    {id, cookies} = begin_login()
    http(operation("wechatMiniWebLoginCancel", id), cookies)

    assert_error(
      http(operation("wechatMiniWebLoginConfirm", id), %{}, token),
      "mini_web_login_cancelled"
    )

    # Expiry must be checked on access, independently of the hourly pruner.
    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "UPDATE wechat_mini_web_login_requests SET status='pending', expires_at=$1 WHERE public_code=$2",
      [~N[2000-01-01 00:00:00], id]
    )

    assert_error(
      http(operation("wechatMiniWebLoginConfirm", id), %{}, token),
      "mini_web_login_expired"
    )
  end

  test "foreign origin cannot start or consume" do
    assert_error(http(@start, %{}, nil, "https://foreign.example"), "mini_web_login_invalid")
    {id, cookies} = begin_login()

    assert_error(
      http(operation("wechatMiniWebLoginConsume", id), cookies, nil, "https://foreign.example"),
      "mini_web_login_invalid"
    )
  end

  test "no implicit replacement of a different existing browser account" do
    {_, mini_token} = account()
    {other, _} = account()
    {:ok, signed} = SignInFlow.generate_token(other, :web, %{})
    {id, cookies} = begin_login()
    http(operation("wechatMiniWebLoginConfirm", id), %{}, mini_token)

    assert_error(
      http(
        operation("wechatMiniWebLoginConsume", id),
        Map.put(cookies, "cgc_token", signed.__metadata__.token)
      ),
      "mini_web_login_account_conflict"
    )
  end

  test "real phone authorization reuses an existing XHS user without SMS or a second User" do
    {existing, _} = account(:xhs)
    count = Ash.count!(User, authorize?: false)
    {id, cookies} = begin_login()

    Cgc2046.MiniprogramFixtures.stub_code2session(%{
      wechat: %{
        "openid" => "mini-web-same-person",
        "session_key" => Cgc2046.MiniprogramFixtures.new_session_key()
      }
    })

    Tesla.Mock.mock(fn %{url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
      Tesla.Mock.json(%{
        "errcode" => 0,
        "phone_info" => %{
          "purePhoneNumber" => String.replace_prefix(existing.phone, "+86", ""),
          "countryCode" => "86"
        }
      })
    end)

    signed =
      http(
        "mutation { signInWithPlatform(platform: \"wechat\", code: \"login-code\", phoneCode: \"phone-code\") { id } }"
      )

    assert get_in(json_response(signed, 200), ["data", "signInWithPlatform", "id"]) == existing.id
    mini_token = signed.resp_cookies["cgc_token"].value

    refute json_response(http(operation("wechatMiniWebLoginConfirm", id), %{}, mini_token), 200)[
             "errors"
           ]

    assert get_in(json_response(http(operation("wechatMiniWebLoginConsume", id), cookies), 200), [
             "data",
             "wechatMiniWebLoginConsume",
             "id"
           ]) == existing.id

    assert Ash.count!(User, authorize?: false) == count

    assert Ecto.Adapters.SQL.query!(
             Cgc2046.Repo,
             "SELECT count(*) FROM phone_verification_codes",
             []
           ).rows == [[0]]
  end

  test "refresh invalidates old proof even after phone confirmation" do
    {_, token} = account()
    {id, cookies} = begin_login()
    http(operation("wechatMiniWebLoginConfirm", id), %{}, token)
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    new = http(@start, cookies)
    refute json_response(new, 200)["errors"]
    assert new.resp_cookies["cgc_mp_web_proof"].value != cookies["cgc_mp_web_proof"]

    assert_error(
      http(operation("wechatMiniWebLoginConsume", id), cookies),
      "mini_web_login_cancelled"
    )
  end

  test "database failure after token revocation rolls back old session and approval" do
    {user, token} = account()
    {:ok, old} = SignInFlow.generate_token(user, :web, %{})
    {id, cookies} = begin_login()
    http(operation("wechatMiniWebLoginConfirm", id), %{}, token)

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "ALTER TABLE wechat_mini_web_login_requests ADD CONSTRAINT test_reject_consume CHECK (status <> 'consumed')",
      []
    )

    assert_error(
      http(operation("wechatMiniWebLoginConsume", id), cookies),
      "mini_web_login_failed"
    )

    Ecto.Adapters.SQL.query!(
      Cgc2046.Repo,
      "ALTER TABLE wechat_mini_web_login_requests DROP CONSTRAINT test_reject_consume",
      []
    )

    assert get_in(http("{ me { id } }", %{}, old.__metadata__.token) |> json_response(200), [
             "data",
             "me",
             "id"
           ]) == user.id

    assert get_in(http(status(id), cookies) |> json_response(200), [
             "data",
             "wechatMiniWebLoginStatus",
             "status"
           ]) == "APPROVED"
  end

  test "new user completes phone authorization and Web registration without SMS" do
    count = Ash.count!(User, authorize?: false)
    {id, cookies} = begin_login()

    Cgc2046.MiniprogramFixtures.stub_code2session(%{
      wechat: %{
        "openid" => "mini-web-new-person",
        "session_key" => Cgc2046.MiniprogramFixtures.new_session_key()
      }
    })

    Tesla.Mock.mock(fn %{url: "https://api.weixin.qq.com/wxa/business/getuserphonenumber" <> _} ->
      Tesla.Mock.json(%{
        "errcode" => 0,
        "phone_info" => %{"purePhoneNumber" => "13800006541", "countryCode" => "86"}
      })
    end)

    signed =
      http(
        "mutation { signInWithPlatform(platform: \"wechat\", code: \"new-person\", phoneCode: \"new-phone\") { id } }"
      )

    user_id = get_in(json_response(signed, 200), ["data", "signInWithPlatform", "id"])
    assert is_binary(user_id)
    mini_token = signed.resp_cookies["cgc_token"].value

    refute json_response(http(operation("wechatMiniWebLoginConfirm", id), %{}, mini_token), 200)[
             "errors"
           ]

    assert get_in(json_response(http(operation("wechatMiniWebLoginConsume", id), cookies), 200), [
             "data",
             "wechatMiniWebLoginConsume",
             "id"
           ]) == user_id

    assert Ash.count!(User, authorize?: false) == count + 1
    assert Ash.get!(User, user_id, @internal).phone == "+8613800006541"

    assert Ecto.Adapters.SQL.query!(
             Cgc2046.Repo,
             "SELECT count(*) FROM phone_verification_codes",
             []
           ).rows == [[0]]
  end

  test "proof rotation cannot reset the browser throttle" do
    {_, cookies} = begin_login()
    assert_error(http(@start, cookies), "rate_limited")
  end

  test "independent connections cannot consume one approval twice" do
    alias Ecto.Adapters.SQL.Sandbox

    {user, id, cookies} =
      Sandbox.unboxed_run(Cgc2046.Repo, fn ->
        {user, token} = account()
        {id, cookies} = begin_login()

        refute json_response(http(operation("wechatMiniWebLoginConfirm", id), %{}, token), 200)[
                 "errors"
               ]

        {user, id, cookies}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Cgc2046.Repo, fn ->
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "DELETE FROM wechat_mini_web_login_requests WHERE public_code=$1",
          [id]
        )

        Ecto.Adapters.SQL.query!(Cgc2046.Repo, "DELETE FROM tokens WHERE subject=$1", [
          AshAuthentication.user_to_subject(user)
        ])

        Ecto.Adapters.SQL.query!(Cgc2046.Repo, "DELETE FROM users WHERE id=$1", [
          Cgc2046.Repo.uuid!(user.id)
        ])
      end)
    end)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Cgc2046.Repo, fn ->
            send(parent, {:ready_to_consume, self()})

            receive do
              :consume -> :ok
            after
              5000 -> raise "barrier timed out"
            end

            http(operation("wechatMiniWebLoginConsume", id), cookies) |> json_response(200)
          end)
        end)
      end

    ready =
      for _ <- tasks do
        assert_receive {:ready_to_consume, pid}
        pid
      end

    Enum.each(ready, &send(&1, :consume))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &get_in(&1, ["data", "wechatMiniWebLoginConsume", "id"])) == 1
    assert Enum.count(results, &(&1["errors"] != nil)) == 1
  end
end
