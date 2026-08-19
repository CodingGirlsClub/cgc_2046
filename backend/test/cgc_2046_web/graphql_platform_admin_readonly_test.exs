defmodule Cgc2046Web.GraphqlPlatformAdminReadonlyTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  test "非成员 PlatformAdmin 仅能创建和撤销 owner 预授权邀请" do
    admin = Fixtures.platform_admin("gql-readonly-invitation-admin")
    workspace = Fixtures.create_workspace(admin)
    Fixtures.remove_membership(workspace, admin)
    token = sign_in_token(admin)

    owner_response =
      graphql(
        create_invitation_mutation(workspace.id, admin.id, ["owner"]),
        token
      )

    assert %{
             "data" => %{
               "createInvitation" => %{
                 "result" => %{"id" => invitation_id, "status" => "active"},
                 "errors" => []
               }
             }
           } = owner_response

    revoke_response =
      graphql(
        """
        mutation {
          revokeInvitation(id: "#{invitation_id}") {
            result { id status }
            errors { code message }
          }
        }
        """,
        token
      )

    assert %{
             "data" => %{
               "revokeInvitation" => %{
                 "result" => %{"id" => ^invitation_id, "status" => "revoked"},
                 "errors" => []
               }
             }
           } = revoke_response
  end

  test "非成员 PlatformAdmin 不能创建普通角色邀请" do
    admin = Fixtures.platform_admin("gql-readonly-ordinary-invitation-admin")
    workspace = Fixtures.create_workspace(admin)
    Fixtures.remove_membership(workspace, admin)

    response =
      graphql(
        create_invitation_mutation(workspace.id, admin.id, ["tutor"]),
        sign_in_token(admin)
      )

    assert %{"data" => %{"createInvitation" => %{"result" => nil, "errors" => errors}}} =
             response

    assert Enum.any?(errors, &(&1["code"] in ["forbidden", "unauthorized"]))
  end

  test "非成员 PlatformAdmin 不能创建 InviteBatch" do
    admin = Fixtures.platform_admin("gql-readonly-invite-batch-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)
    Fixtures.remove_membership(workspace, admin)

    response =
      graphql(
        """
        mutation {
          createInviteBatch(input: {
            eventId: "#{event.id}"
            inviteCode: "READONLY"
            quota: 1
          }) {
            result { id }
            errors { code message }
          }
        }
        """,
        sign_in_token(admin)
      )

    assert %{"data" => %{"createInviteBatch" => %{"result" => nil, "errors" => errors}}} =
             response

    assert Enum.any?(errors, &(&1["code"] in ["forbidden", "unauthorized"]))
  end

  test "成员 Owner 的普通角色邀请路径保持可用" do
    admin = Fixtures.platform_admin("gql-readonly-member-inviter")
    workspace = Fixtures.create_workspace(admin)

    response =
      graphql(
        create_invitation_mutation(workspace.id, admin.id, ["tutor"]),
        sign_in_token(admin)
      )

    assert %{
             "data" => %{
               "createInvitation" => %{
                 "result" => %{"status" => "active"},
                 "errors" => []
               }
             }
           } = response
  end

  defp create_invitation_mutation(workspace_id, inviter_id, role_names) do
    roles = Enum.map_join(role_names, ", ", &~s("#{&1}"))

    """
    mutation {
      createInvitation(input: {
        workspaceId: "#{workspace_id}"
        inviterId: "#{inviter_id}"
        preauthorizedRoleNames: [#{roles}]
      }) {
        result { id status }
        errors { code message }
      }
    }
    """
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(login: "#{user.email}", password: "#{Fixtures.password()}") { id }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => mutation})

    assert %{"data" => %{"signIn" => %{"id" => _}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
