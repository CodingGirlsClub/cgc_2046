defmodule Cgc2046Web.GraphqlSignInRateLimitTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046Web.Plugs.RateLimit

  @email "sign-in-rate-limit@example.com"
  @password "sign-in-rate-limit-password"
  @ip {10, 20, 30, 40}

  setup do
    previous = Application.get_env(:cgc_2046, RateLimit)
    previous_limits = Application.get_env(:cgc_2046, :rate_limits)
    :ets.delete_all_objects(RateLimit.table())
    Application.put_env(:cgc_2046, RateLimit, max_attempts: 5)
    Application.put_env(:cgc_2046, :rate_limits, sign_in_ip: 30)

    on_exit(fn ->
      :ets.delete_all_objects(RateLimit.table())
      restore_env(RateLimit, previous)
      restore_env(:rate_limits, previous_limits)
    end)

    user =
      Cgc2046.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: @email,
        password: @password
      })
      |> Ash.create!()

    {:ok, user: user}
  end

  test "30 different logins exhaust the IP budget before a valid password can sign in" do
    for i <- 1..30 do
      assert_authentication_failed(sign_in("spray-#{i}@example.com"))
    end

    assert_rate_limited(sign_in(@email, @password))
    assert_rate_limited(sign_in("unknown-account@example.com"))
  end

  test "another real remote IP can sign in after the first IP exhausts its budget", %{user: user} do
    for i <- 1..30, do: assert_authentication_failed(sign_in("spray-#{i}@example.com"))
    assert_rate_limited(sign_in(@email, @password))
    assert_signed_in(sign_in(@email, @password, {10, 20, 30, 41}), user)
  end

  test "the sixth attempt is blocked for one login but not another login or IP", %{user: user} do
    for _ <- 1..5, do: assert_authentication_failed(sign_in(@email))
    assert_rate_limited(sign_in(@email, @password))
    assert_authentication_failed(sign_in("another-login@example.com"))
    assert_signed_in(sign_in(@email, @password, {10, 20, 30, 41}), user)
  end

  test "email case and whitespace cannot bypass the login budget" do
    for login <- [@email, String.upcase(@email), "  #{@email}  ", @email, @email] do
      assert_authentication_failed(sign_in(login))
    end

    assert_rate_limited(sign_in(String.upcase(@email)))
  end

  test "equivalent phone formats cannot bypass the login budget" do
    for login <- [
          "13800139850",
          "+8613800139850",
          "+86 138-0013-9850",
          "13800139850",
          "13800139850"
        ] do
      assert_authentication_failed(sign_in(login))
    end

    assert_rate_limited(sign_in("+86 138-0013-9850"))
  end

  test "attempts rejected by the login bucket still consume the IP budget" do
    for _ <- 1..5, do: assert_authentication_failed(sign_in("repeated@example.com"))
    for _ <- 6..30, do: assert_rate_limited(sign_in("repeated@example.com"))
    assert_rate_limited(sign_in(@email, @password))
  end

  test "successful sign-ins count toward the IP budget", %{user: user} do
    assert_signed_in(sign_in(@email, @password), user)
    for i <- 1..29, do: assert_authentication_failed(sign_in("spray-#{i}@example.com"))
    assert_rate_limited(sign_in(@email, @password))
  end

  test "the IP budget resets at the end of the 900 second window", %{user: user} do
    for i <- 1..30, do: assert_authentication_failed(sign_in("spray-#{i}@example.com"))
    assert_rate_limited(sign_in(@email, @password))

    key = RateLimit.build_key("rate:sign-in:ip", "10.20.30.40")
    [{^key, count, _start}] = :ets.lookup(RateLimit.table(), key)
    :ets.insert(RateLimit.table(), {key, count, System.system_time(:second) - 900})

    assert_signed_in(sign_in(@email, @password), user)
  end

  defp assert_signed_in(conn, user) do
    assert %{"data" => %{"signIn" => %{"id" => id, "email" => @email}}} = json_response(conn, 200)
    assert id == user.id
    assert conn.resp_cookies["cgc_token"].http_only == true
  end

  defp sign_in(login, password \\ "wrong-password", ip \\ @ip) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{
      "query" =>
        "mutation($login: String!, $password: String!) { signIn(login: $login, password: $password) { id email } }",
      "variables" => %{"login" => login, "password" => password}
    })
  end

  defp assert_authentication_failed(conn) do
    assert %{
             "data" => %{"signIn" => nil},
             "errors" => [
               %{"code" => "authentication_failed", "message" => "Invalid email or password"}
             ]
           } = json_response(conn, 200)
  end

  defp assert_rate_limited(conn) do
    assert %{
             "data" => %{"signIn" => nil},
             "errors" => [
               %{"code" => "rate_limited", "message" => "Too many requests. Try again later."}
             ]
           } = json_response(conn, 200)

    refute Map.has_key?(conn.resp_cookies, "cgc_token")
  end

  defp restore_env(key, nil), do: Application.delete_env(:cgc_2046, key)
  defp restore_env(key, value), do: Application.put_env(:cgc_2046, key, value)
end
