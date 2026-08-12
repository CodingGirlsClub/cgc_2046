defmodule Cgc2046Web.GraphqlAcceptInvitationTest do
  # async: false —— 与 GraphqlInvitationRateLimitTest 共享全局 RateLimit ETS 表，
  # acceptInvitation 的限流 key（input.token）相同，避免计数互相污染。
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.AccountsFixtures, as: Fixtures

  require Ash.Query

  defp create_invitation(workspace, inviter, attrs \\ %{}) do
    {:ok, invitation} =
      Invitation
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{workspace_id: workspace.id, inviter_id: inviter.id},
          Map.new(attrs)
        )
      )
      |> Ash.create(actor: inviter)

    invitation
  end

  defp plain_token(invitation), do: invitation.__metadata__[:plain_token]

  defp sign_in_token(email) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{Fixtures.password()}") {
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

  defp accept_invitation(authed_or_nil, id, token) do
    mutation = """
    mutation {
      acceptInvitation(id: "#{id}", input: { token: "#{token}" }) {
        result { id status }
        errors { message code }
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      if authed_or_nil do
        put_req_header(conn, "authorization", "Bearer #{authed_or_nil}")
      else
        conn
      end

    conn
    |> post("/api/graphql", %{"query" => mutation})
    |> json_response(200)
  end

  defp mutation_result(res), do: get_in(res, ["data", "acceptInvitation", "result"])
  defp mutation_errors(res), do: get_in(res, ["data", "acceptInvitation", "errors"]) || []

  defp membership_of(workspace_id, user_id) do
    [membership] =
      WorkspaceMembership
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!(tenant: workspace_id, authorize?: false)

    membership
  end

  describe "acceptInvitation" do
    test "受邀者（非 inviter、非 Owner/Admin）accept 成功，建立 membership + 预授权角色" do
      admin = Fixtures.platform_admin("gql-accept-platform")
      workspace = Fixtures.create_workspace(admin)
      acceptor = Fixtures.register_user("gql-accept-acceptor")
      invitation = create_invitation(workspace, admin, preauthorized_role_names: [:member])
      authed = sign_in_token(acceptor.email)

      res = accept_invitation(authed, invitation.id, plain_token(invitation))

      assert %{"status" => "used"} = mutation_result(res)
      assert mutation_errors(res) == []

      membership = membership_of(workspace.id, acceptor.id)
      loaded = Ash.load!(membership, :roles, tenant: workspace.id, authorize?: false)
      assert Enum.map(loaded.roles, & &1.name) == [:member]
    end

    test "inviter（已是成员）接受自己邀请 → 到达业务逻辑「你已是该工作台成员」" do
      admin = Fixtures.platform_admin("gql-accept-inviter-platform")
      workspace = Fixtures.create_workspace(admin)
      invitation = create_invitation(workspace, admin)
      authed = sign_in_token(admin.email)

      res = accept_invitation(authed, invitation.id, plain_token(invitation))

      assert mutation_result(res) == nil
      assert Enum.any?(mutation_errors(res), &(&1["message"] == "你已是该工作台成员"))
    end

    test "已消费的邀请重复 accept → Invitation has already been used" do
      admin = Fixtures.platform_admin("gql-accept-used-platform")
      workspace = Fixtures.create_workspace(admin)
      acceptor = Fixtures.register_user("gql-accept-used-acceptor")
      invitation = create_invitation(workspace, admin)
      authed = sign_in_token(acceptor.email)

      assert %{"status" => "used"} =
               mutation_result(accept_invitation(authed, invitation.id, plain_token(invitation)))

      res = accept_invitation(authed, invitation.id, plain_token(invitation))

      assert mutation_result(res) == nil

      assert Enum.any?(
               mutation_errors(res),
               &(&1["message"] == "Invitation has already been used")
             )
    end

    test "错误 token → not_found（不泄露邀请存在性）" do
      admin = Fixtures.platform_admin("gql-accept-badtoken-platform")
      workspace = Fixtures.create_workspace(admin)
      acceptor = Fixtures.register_user("gql-accept-badtoken-acceptor")
      invitation = create_invitation(workspace, admin)
      authed = sign_in_token(acceptor.email)

      res = accept_invitation(authed, invitation.id, "wrong-token")

      assert mutation_result(res) == nil
      assert Enum.any?(mutation_errors(res), &(&1["code"] == "not_found"))
    end

    test "未知 id → not_found" do
      acceptor = Fixtures.register_user("gql-accept-unknown-acceptor")
      authed = sign_in_token(acceptor.email)

      res = accept_invitation(authed, Ecto.UUID.generate(), "whatever-token")

      assert mutation_result(res) == nil
      assert Enum.any?(mutation_errors(res), &(&1["code"] == "not_found"))
    end

    test "受邀者已是该工作台成员 → 你已是该工作台成员" do
      admin = Fixtures.platform_admin("gql-accept-member-platform")
      workspace = Fixtures.create_workspace(admin)
      acceptor = Fixtures.register_user("gql-accept-member-acceptor")
      Fixtures.add_member(workspace, acceptor, [:member])
      invitation = create_invitation(workspace, admin)
      authed = sign_in_token(acceptor.email)

      res = accept_invitation(authed, invitation.id, plain_token(invitation))

      assert mutation_result(res) == nil
      assert Enum.any?(mutation_errors(res), &(&1["message"] == "你已是该工作台成员"))
    end
  end
end
