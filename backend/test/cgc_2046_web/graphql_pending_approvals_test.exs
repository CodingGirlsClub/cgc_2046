defmodule Cgc2046Web.GraphqlPendingApprovalsTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Phase2Fixtures, as: Fixtures

  @password "sup3r-secret-password"

  @query """
  query {
    myPendingApprovals {
      id
      kind
      workspaceId
      userId
      eventId
      courseId
      status
      approvalDeadline
    }
  }
  """

  test "Owner 只聚合自己管理 workspace 的 Enrollment + JoinRequest，并按 deadline 升序" do
    platform_admin = Fixtures.platform_admin("pending-platform")
    owner = Fixtures.register_user("pending-owner")
    other_owner = Fixtures.register_user("pending-other-owner")
    applicant_a = Fixtures.register_user("pending-applicant-a")
    applicant_b = Fixtures.register_user("pending-applicant-b")
    applicant_other = Fixtures.register_user("pending-applicant-other")

    workspace = Fixtures.create_workspace(platform_admin, %{name: "Managed"})
    other_workspace = Fixtures.create_workspace(platform_admin, %{name: "Other"})
    Fixtures.add_member(workspace, owner, [:owner])
    Fixtures.add_member(other_workspace, other_owner, [:owner])

    event = Fixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})

    enrollment = create_pending_enrollment(event, applicant_a)
    join_request = create_join_request(workspace, applicant_b)
    _other = create_join_request(other_workspace, applicant_other)

    set_deadline("enrollments", enrollment.id, "2026-08-10 00:00:00")
    set_deadline("join_requests", join_request.id, "2026-08-09 00:00:00")

    response = graphql(@query, sign_in_token(owner))

    assert %{"data" => %{"myPendingApprovals" => approvals}} = response
    assert Enum.map(approvals, & &1["kind"]) == ["join_request", "enrollment"]
    assert Enum.map(approvals, & &1["workspaceId"]) == [workspace.id, workspace.id]
    refute Enum.any?(approvals, &(&1["userId"] == applicant_other.id))
  end

  test "普通成员与非成员查询均为空，不泄露 pending 审批" do
    platform_admin = Fixtures.platform_admin("pending-deny-platform")
    member = Fixtures.register_user("pending-member")
    outsider = Fixtures.register_user("pending-outsider")
    applicant = Fixtures.register_user("pending-deny-applicant")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, member, [:member])
    _pending = create_join_request(workspace, applicant)

    assert %{"data" => %{"myPendingApprovals" => []}} =
             graphql(@query, sign_in_token(member))

    assert %{"data" => %{"myPendingApprovals" => []}} =
             graphql(@query, sign_in_token(outsider))
  end

  defp create_pending_enrollment(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create!(tenant: event.workspace_id, actor: user)
  end

  defp create_join_request(workspace, user) do
    JoinRequest
    |> Ash.Changeset.for_create(:create, %{workspace_id: workspace.id, user_id: user.id})
    |> Ash.create!(actor: user)
  end

  defp set_deadline(table, id, timestamp) do
    {:ok, deadline, 0} = DateTime.from_iso8601(timestamp <> "Z")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET approval_deadline = $1 WHERE id = $2",
        [deadline, Ecto.UUID.dump!(id)]
      )
  end

  defp sign_in_token(user) do
    mutation = """
    mutation {
      signIn(email: "#{user.email}", password: "#{@password}") { id }
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
