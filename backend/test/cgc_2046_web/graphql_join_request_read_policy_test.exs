defmodule Cgc2046Web.GraphqlJoinRequestReadPolicyTest do
  @moduledoc """
  #706：JoinRequest read policy 的 Owner/Admin 分支必须是资源级 FilterCheck。
  GraphQL 的 `or` filter 不能扩大 Owner/Admin 可见的 workspace 行集。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.AccountsFixtures, as: Fixtures

  test "Owner 的 workspace 查询返回全部申请及公开字段" do
    setup = cross_workspace_setup()

    query = """
    query {
      joinRequests(
        first: 50
        filter: {workspaceId: {eq: "#{setup.workspace_x.id}"}}
      ) {
        results { id workspaceId userId status message }
      }
    }
    """

    assert %{"data" => %{"joinRequests" => %{"results" => rows}}} =
             graphql(query, setup.owner_token)

    assert rows != []
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.workspace_x.id))

    assert Enum.any?(rows, fn row ->
             row["userId"] == setup.applicant.id and
               row["status"] == "pending" and
               row["message"] == "workspace x request"
           end)
  end

  test "Admin 的 workspace 查询返回全部申请" do
    setup = cross_workspace_setup()

    query = """
    query {
      joinRequests(first: 50, filter: {workspaceId: {eq: "#{setup.workspace_x.id}"}}) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"joinRequests" => %{"results" => rows}}} =
             graphql(query, setup.admin_token)

    assert rows != []
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.workspace_x.id))
    assert Enum.any?(rows, &(&1["userId"] == setup.applicant.id))
  end

  test "Owner 的 workspaceId OR userId filter 不能返回其他 workspace" do
    setup = cross_workspace_setup()

    query = """
    query {
      joinRequests(
        first: 50
        filter: {or: [
          {workspaceId: {eq: "#{setup.workspace_x.id}"}},
          {userId: {eq: "#{setup.victim.id}"}}
        ]}
      ) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"joinRequests" => %{"results" => rows}}} =
             graphql(query, setup.owner_token)

    assert rows != []
    assert Enum.all?(rows, &(&1["workspaceId"] == setup.workspace_x.id))
    refute Enum.any?(rows, &(&1["id"] == setup.victim_row_id))
  end

  test "非成员 PlatformAdmin 可读取跨 workspace 的 JoinRequest" do
    setup = cross_workspace_setup()

    query = """
    query {
      joinRequests(first: 50) {
        results { id workspaceId userId }
      }
    }
    """

    assert %{"data" => %{"joinRequests" => %{"results" => rows}}} =
             graphql(query, setup.platform_admin_token)

    workspace_ids = rows |> Enum.map(& &1["workspaceId"]) |> MapSet.new()

    assert MapSet.member?(workspace_ids, setup.workspace_x.id)
    assert MapSet.member?(workspace_ids, setup.workspace_y.id)
  end

  defp cross_workspace_setup do
    platform_admin = Fixtures.platform_admin("jr-read-platform")
    non_member_platform_admin = Fixtures.platform_admin("jr-read-platform-other")
    applicant = Fixtures.register_user("jr-read-applicant")
    victim = Fixtures.register_user("jr-read-victim")

    %{owner: owner, workspace: workspace_x, member: admin} =
      Fixtures.workspace_with_member(member_roles: [:admin])

    workspace_y = Fixtures.create_workspace(platform_admin)

    _owner_request =
      create_join_request(workspace_x, owner, %{message: "owner request"})

    _applicant_request =
      create_join_request(workspace_x, applicant, %{message: "workspace x request"})

    victim_row = create_join_request(workspace_y, victim, %{message: "workspace y request"})

    %{
      workspace_x: workspace_x,
      workspace_y: workspace_y,
      owner: owner,
      admin: admin,
      applicant: applicant,
      victim: victim,
      victim_row_id: victim_row.id,
      owner_token: sign_in_token(owner),
      admin_token: sign_in_token(admin),
      platform_admin_token: sign_in_token(non_member_platform_admin)
    }
  end

  defp create_join_request(workspace, user, attrs) do
    JoinRequest
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{workspace_id: workspace.id, user_id: user.id}, attrs)
    )
    |> Ash.create!(actor: user)
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
