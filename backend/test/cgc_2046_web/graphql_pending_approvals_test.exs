defmodule Cgc2046Web.GraphqlPendingApprovalsTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

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

    event = EventFixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})

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

  test "行含 requester/context 摘要（E-8 D7 行形状）" do
    platform_admin = Fixtures.platform_admin("summary-platform")
    owner = Fixtures.register_user("summary-owner")
    applicant = Fixtures.register_user("summary-applicant")
    workspace = Fixtures.create_workspace(platform_admin, %{name: "Summary WS"})
    Fixtures.add_member(workspace, owner, [:owner])

    event =
      EventFixtures.create_event(workspace, platform_admin, %{
        enrollment_policy: :request,
        title: "教研分享会"
      })

    _enrollment = create_pending_enrollment(event, applicant)
    _join = create_join_request(workspace, applicant)

    query = """
    query {
      myPendingApprovals {
        kind
        requesterName
        workspaceName
        contextTitle
        expiredAt
      }
    }
    """

    assert %{"data" => %{"myPendingApprovals" => rows}} = graphql(query, sign_in_token(owner))
    assert length(rows) == 2

    enrollment_row = Enum.find(rows, &(&1["kind"] == "enrollment"))
    join_row = Enum.find(rows, &(&1["kind"] == "join_request"))

    # fixture 未设 display_name → 摘要回落 email
    assert enrollment_row["requesterName"] == to_string(applicant.email)
    assert enrollment_row["workspaceName"] == "Summary WS"
    assert enrollment_row["contextTitle"] == "教研分享会"
    assert is_nil(enrollment_row["expiredAt"])

    # JoinRequest 无活动上下文：context 摘要回落 Workspace 名
    assert join_row["contextTitle"] == "Summary WS"
  end

  # /approvals 展示含 status=expired 行。角标计数不含过期 pending（KTD8），
  # 对侧：graphql_pending_approvals_count_test.exs。
  test "include_expired=true 附带已过期行（只读，排在 pending 后）" do
    platform_admin = Fixtures.platform_admin("expired-platform")
    owner = Fixtures.register_user("expired-owner")
    applicant = Fixtures.register_user("expired-applicant")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, owner, [:owner])
    event = EventFixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})

    pending = create_pending_enrollment(event, applicant)
    expired_user = Fixtures.register_user("expired-applicant-2")
    expired = create_pending_enrollment(event, expired_user)
    set_status("enrollments", expired.id, "expired")

    query = """
    query {
      withExpired: myPendingApprovals(includeExpired: true) { id status expiredAt }
      pendingOnly: myPendingApprovals { id status }
    }
    """

    assert %{"data" => %{"withExpired" => all, "pendingOnly" => only}} =
             graphql(query, sign_in_token(owner))

    assert Enum.map(all, & &1["status"]) == ["pending", "expired"]
    assert length(only) == 1
    assert hd(only)["id"] == pending.id

    expired_row = Enum.find(all, &(&1["status"] == "expired"))
    assert expired_row["id"] == expired.id
  end

  test "多条 expired 行按 expired_at 倒序且不 crash（评审回归：DateTime sorter 键）" do
    platform_admin = Fixtures.platform_admin("expsort-platform")
    owner = Fixtures.register_user("expsort-owner")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, owner, [:owner])
    event = EventFixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})

    older_user = Fixtures.register_user("expsort-older")
    newer_user = Fixtures.register_user("expsort-newer")
    older = create_pending_enrollment(event, older_user)
    newer = create_pending_enrollment(event, newer_user)
    set_status("enrollments", older.id, "expired", "2026-08-11 00:00:00")
    set_status("enrollments", newer.id, "expired", "2026-08-12 00:00:00")

    query = """
    query { myPendingApprovals(includeExpired: true) { id status } }
    """

    assert %{"data" => %{"myPendingApprovals" => rows}} = graphql(query, sign_in_token(owner))
    assert Enum.map(rows, & &1["id"]) == [newer.id, older.id]
  end

  test "普通成员与非成员查询均为空，不泄露 pending 审批" do
    platform_admin = Fixtures.platform_admin("pending-deny-platform")
    member = Fixtures.register_user("pending-member")
    outsider = Fixtures.register_user("pending-outsider")
    applicant = Fixtures.register_user("pending-deny-applicant")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, member)
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

  defp set_status(table, id, status, expired_at \\ nil) do
    {:ok, expired_at_dt, 0} = DateTime.from_iso8601((expired_at || "2026-08-12 00:00:00") <> "Z")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE #{table} SET status = $1, expired_at = $2 WHERE id = $3",
        [status, expired_at_dt, Ecto.UUID.dump!(id)]
      )
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
      signIn(email: "#{user.email}", password: "#{Fixtures.password()}") { id }
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
