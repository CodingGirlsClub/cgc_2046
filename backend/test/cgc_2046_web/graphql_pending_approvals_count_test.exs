defmodule Cgc2046Web.GraphqlPendingApprovalsCountTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures

  # 角标计数口径 ≠ /approvals 展示口径（KTD8）。对侧：graphql_pending_approvals_test.exs。
  @query "query { pendingApprovalsCount }"
  @tier %{
    "id" => "9d2f7c80-0000-4000-8000-0000000000ab",
    "name" => "冠名",
    "amount_suggestion" => 10_000,
    "benefits" => ["logo 展示位"],
    "exclusive" => true
  }

  test "Owner/Admin 跨两个工作台计数 Enrollment、JoinRequest、Sponsorship" do
    platform_admin = Fixtures.platform_admin("pending-count-platform")
    owner = Fixtures.register_user("pending-count-owner")
    enrollment_user = Fixtures.register_user("pending-count-enrollment")
    join_user = Fixtures.register_user("pending-count-join")
    sponsor = Fixtures.register_user("pending-count-sponsor")

    workspace_a = Fixtures.create_workspace(platform_admin, %{sponsorship_tiers: [@tier]})
    workspace_b = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace_a, owner, [:owner])
    Fixtures.add_member(workspace_b, owner, [:admin])

    event_a =
      EventFixtures.create_event(workspace_a, platform_admin, %{
        enrollment_policy: :request,
        sponsorship_tiers: [@tier]
      })

    _enrollment = create_pending_enrollment(event_a, enrollment_user)
    _join_request = create_join_request(workspace_b, join_user)
    _sponsorship = create_pending_sponsorship(event_a, sponsor)

    assert %{"data" => %{"pendingApprovalsCount" => 3}} =
             graphql(@query, sign_in_token(owner))
  end

  # KTD8：deadline 已过但 status 仍 pending 不计。/approvals 列表仍会展示这类行
  # （graphql_pending_approvals_test.exs 的 pending 区按 status=pending）。
  test "过期但仍 pending 的行不计入" do
    platform_admin = Fixtures.platform_admin("pending-count-expired-platform")
    owner = Fixtures.register_user("pending-count-expired-owner")
    applicant = Fixtures.register_user("pending-count-expired-applicant")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, owner, [:owner])
    event = EventFixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})

    enrollment = create_pending_enrollment(event, applicant)
    set_deadline("enrollments", enrollment.id, DateTime.add(DateTime.utc_now(), -1, :hour))

    assert %{"data" => %{"pendingApprovalsCount" => 0}} =
             graphql(@query, sign_in_token(owner))
  end

  test "普通成员计数为 0" do
    platform_admin = Fixtures.platform_admin("pending-count-member-platform")
    member = Fixtures.register_user("pending-count-member")
    applicant = Fixtures.register_user("pending-count-member-applicant")
    workspace = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace, member)
    event = EventFixtures.create_event(workspace, platform_admin, %{enrollment_policy: :request})
    _enrollment = create_pending_enrollment(event, applicant)

    assert %{"data" => %{"pendingApprovalsCount" => 0}} =
             graphql(@query, sign_in_token(member))
  end

  test "未登录返回 unauthorized" do
    response = graphql(@query, nil)

    assert %{"data" => nil, "errors" => [%{"code" => "unauthorized"}]} = response
  end

  test "双账号隔离待办计数" do
    platform_admin = Fixtures.platform_admin("pending-count-isolation-platform")
    owner_a = Fixtures.register_user("pending-count-isolation-owner-a")
    owner_b = Fixtures.register_user("pending-count-isolation-owner-b")
    applicant_a = Fixtures.register_user("pending-count-isolation-applicant-a")
    applicant_b = Fixtures.register_user("pending-count-isolation-applicant-b")
    workspace_a = Fixtures.create_workspace(platform_admin)
    workspace_b = Fixtures.create_workspace(platform_admin)
    Fixtures.add_member(workspace_a, owner_a, [:owner])
    Fixtures.add_member(workspace_b, owner_b, [:owner])

    event_a =
      EventFixtures.create_event(workspace_a, platform_admin, %{enrollment_policy: :request})

    event_b =
      EventFixtures.create_event(workspace_b, platform_admin, %{enrollment_policy: :request})

    _enrollment_a = create_pending_enrollment(event_a, applicant_a)
    _enrollment_b = create_pending_enrollment(event_b, applicant_b)

    assert %{"data" => %{"pendingApprovalsCount" => 1}} =
             graphql(@query, sign_in_token(owner_a))

    assert %{"data" => %{"pendingApprovalsCount" => 1}} =
             graphql(@query, sign_in_token(owner_b))
  end

  # 拍板 #4 读面行级过滤（count 路径同规则）：admin（非 owner）的 workspace 级
  # 赞助不计入角标；owner 两级都计。
  test "Sponsorship count 行级过滤：admin 排除 workspace 级、owner 两级都计" do
    platform_admin = Fixtures.platform_admin("sponsor-count-level-platform")
    owner = Fixtures.register_user("sponsor-count-level-owner")
    admin = Fixtures.register_user("sponsor-count-level-admin")
    sponsor = Fixtures.register_user("sponsor-count-level-sponsor")
    ws_sponsor = Fixtures.register_user("sponsor-count-level-ws-sponsor")

    workspace = Fixtures.create_workspace(platform_admin, %{sponsorship_tiers: [@tier]})
    Fixtures.add_member(workspace, owner, [:owner])
    Fixtures.add_member(workspace, admin, [:admin])
    event = EventFixtures.create_event(workspace, platform_admin, %{sponsorship_tiers: [@tier]})

    _event_sponsorship = create_pending_sponsorship(event, sponsor)
    _ws_sponsorship = create_workspace_sponsorship(workspace, ws_sponsor)

    assert %{"data" => %{"pendingApprovalsCount" => 2}} =
             graphql(@query, sign_in_token(owner))

    assert %{"data" => %{"pendingApprovalsCount" => 1}} =
             graphql(@query, sign_in_token(admin))
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

  defp create_pending_sponsorship(event, sponsor) do
    Sponsorship
    |> Ash.Changeset.for_create(:create_sponsorship, %{
      level: :event,
      event_id: event.id,
      sponsor_user_id: sponsor.id,
      tier_id: @tier["id"],
      amount: 10_000,
      company_name: "计数赞助方",
      contact_email: sponsor.email
    })
    |> Ash.create!(tenant: event.workspace_id, actor: sponsor)
  end

  defp create_workspace_sponsorship(workspace, sponsor) do
    Sponsorship
    |> Ash.Changeset.for_create(:create_sponsorship, %{
      level: :workspace,
      target_workspace_id: workspace.id,
      sponsor_user_id: sponsor.id,
      tier_id: @tier["id"],
      amount: 10_000,
      company_name: "长期赞助方",
      contact_email: sponsor.email
    })
    |> Ash.create!(tenant: workspace.id, actor: sponsor)
  end

  defp set_deadline(table, id, deadline) do
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
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
