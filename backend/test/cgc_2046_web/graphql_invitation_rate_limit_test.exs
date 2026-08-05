defmodule Cgc2046Web.GraphqlInvitationRateLimitTest do
  # async: false —— RateLimit 用全局 ETS 表 :cgc_rate_limiter，
  # async: true 会与其他测试的限流计数互相污染。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  setup do
    :ets.delete_all_objects(Cgc2046Web.Plugs.RateLimit.table())
    Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 3)

    on_exit(fn ->
      Application.put_env(:cgc_2046, Cgc2046Web.Plugs.RateLimit, max_attempts: 999_999)
    end)

    :ok
  end

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    assert {:ok, user} =
             AshAuthentication.Strategy.action(password_strategy(), :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp admin_user(email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{
               slug: "rl-ws-#{System.unique_integer([:positive])}",
               name: "RL WS",
               join_policy: :request
             })
             |> Ash.create(actor: admin)

    workspace
  end

  defp create_invitation(workspace, inviter) do
    {:ok, invitation} =
      Invitation
      |> Ash.Changeset.for_create(:create, %{
        workspace_id: workspace.id,
        inviter_id: inviter.id
      })
      |> Ash.create(actor: inviter)

    invitation
  end

  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{@password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp validate_invitation(conn, token) do
    query = """
    query {
      validateInvitation(token: "#{token}") {
        id
        status
        workspaceName
      }
    }
    """

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  describe "validateInvitation rate limit" do
    test "blocks after max_attempts with the same token" do
      admin = admin_user("rl-admin@example.com")
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)
      token = invitation.__metadata__[:plain_token]

      # 前 3 次放行（max_attempts: 3）
      for i <- 1..3 do
        res = validate_invitation(build_conn(), token)
        refute rate_limited?(res), "attempt #{i} should not be rate-limited"
      end

      # 第 4 次被拦
      res = validate_invitation(build_conn(), token)
      assert rate_limited?(res)
    end

    test "different tokens have independent counters" do
      admin = admin_user("rl-admin-2@example.com")
      workspace = create_workspace(admin)
      inv_a = create_invitation(workspace, admin)
      inv_b = create_invitation(workspace, admin)
      token_a = inv_a.__metadata__[:plain_token]
      token_b = inv_b.__metadata__[:plain_token]

      # token_a 打满额度
      for _ <- 1..3, do: validate_invitation(build_conn(), token_a)

      assert rate_limited?(validate_invitation(build_conn(), token_a))
      # token_b 仍放行（key 含 token，独立计数）
      refute rate_limited?(validate_invitation(build_conn(), token_b))
    end
  end

  describe "acceptInvitation rate limit" do
    test "blocks after max_attempts with the same token" do
      admin = admin_user("rl-admin-3@example.com")
      workspace = create_workspace(admin)
      invitation = create_invitation(workspace, admin)
      token = invitation.__metadata__[:plain_token]

      _acceptor = register_user("rl-acceptor@example.com")
      authed = sign_in_token("rl-acceptor@example.com")

      mutation = """
      mutation {
        acceptInvitation(
          id: "#{invitation.id}"
          input: { token: "#{token}" }
        ) {
          result { id }
          errors { message code }
        }
      }
      """

      # 前 3 次：首次 accept 会消费 invitation（status→used），后续会返回业务错误，
      # 但都不是 rate_limited —— 证明请求穿过了 middleware 到达 Ash。
      for i <- 1..3 do
        res =
          build_conn()
          |> put_req_header("authorization", "Bearer #{authed}")
          |> put_req_header("content-type", "application/json")
          |> post("/api/graphql", %{"query" => mutation})
          |> json_response(200)

        refute rate_limited?(res), "attempt #{i} should not be rate-limited, got: #{inspect(res)}"
      end

      # 第 4 次被拦
      res =
        build_conn()
        |> put_req_header("authorization", "Bearer #{authed}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/graphql", %{"query" => mutation})
        |> json_response(200)

      assert rate_limited?(res)
    end
  end

  defp rate_limited?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"code" => "rate_limited"} -> true
      %{"message" => m} when is_binary(m) -> String.contains?(m, "Too many requests")
      _ -> false
    end)
  end

  defp rate_limited?(_), do: false
end
