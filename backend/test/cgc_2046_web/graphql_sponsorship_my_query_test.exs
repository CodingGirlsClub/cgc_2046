defmodule Cgc2046Web.GraphqlSponsorshipMyQueryTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @tier %{
    "id" => "9d2f7c80-0000-4000-8000-0000000000ac",
    "name" => "合作档位",
    "amount_suggestion" => 10_000,
    "benefits" => ["官网 Logo 展示"],
    "exclusive" => true
  }

  test "本人可读取 Event/Workspace 级赞助及 active 交付履约" do
    admin = Fixtures.platform_admin("my-sponsorships-admin")
    workspace = Fixtures.create_workspace(admin, %{name: "赞助工作台", sponsorship_tiers: [@tier]})
    owner = Fixtures.register_user("my-sponsorships-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    event =
      EventFixtures.create_event(workspace, owner, %{title: "赞助活动", sponsorship_tiers: [@tier]})

    pending_event = EventFixtures.create_event(workspace, owner, %{title: "待审赞助活动"})
    sponsor = Fixtures.register_user("my-sponsorships-sponsor")

    event_sponsorship =
      create_sponsorship(workspace, sponsor, %{
        level: :event,
        event_id: event.id,
        tier_id: @tier["id"],
        amount: 10_000,
        company_name: "Event Sponsor",
        contact_email: sponsor.email
      })

    workspace_sponsorship =
      create_sponsorship(workspace, sponsor, %{
        level: :workspace,
        tier_id: @tier["id"],
        target_workspace_id: workspace.id,
        amount: 20_000,
        company_name: "Workspace Sponsor",
        contact_email: sponsor.email
      })

    pending_sponsorship =
      create_sponsorship(workspace, sponsor, %{
        level: :event,
        event_id: pending_event.id,
        company_name: "Pending Sponsor",
        contact_email: sponsor.email
      })

    active_event = approve(event_sponsorship, workspace, owner)
    active_workspace = approve(workspace_sponsorship, workspace, owner)

    response =
      graphql(
        """
        query {
          mySponsorships(first: 20) {
            count
            results {
              id
              level
              status
              tierName
              amount
              targetTitle
              approvedAt
              rejectionReason
              endedAt
              deliveries { benefit dueDate fulfilledAt }
            }
          }
        }
        """,
        sign_in_token(sponsor)
      )

    assert %{"data" => %{"mySponsorships" => %{"count" => 3, "results" => rows}}} = response
    assert Enum.find(rows, &(&1["id"] == active_event.id))["targetTitle"] == "赞助活动"
    assert Enum.find(rows, &(&1["id"] == active_workspace.id))["targetTitle"] == "赞助工作台"

    active_rows = Enum.filter(rows, &(&1["status"] == "active"))
    assert length(active_rows) == 2
    assert Enum.all?(active_rows, &(length(&1["deliveries"]) == 1))
    assert Enum.find(rows, &(&1["id"] == pending_sponsorship.id))["deliveries"] == []
    assert Enum.find(rows, &(&1["id"] == pending_sponsorship.id))["status"] == "pending"
  end

  test "赞助查询按 sponsor actor 隔离且未登录被拒" do
    admin = Fixtures.platform_admin("my-sponsorships-auth-admin")
    workspace = Fixtures.create_workspace(admin)
    owner = Fixtures.register_user("my-sponsorships-auth-owner")
    Fixtures.add_member(workspace, owner, [:owner])
    event = EventFixtures.create_event(workspace, owner)
    sponsor = Fixtures.register_user("my-sponsorships-auth-sponsor")
    other_sponsor = Fixtures.register_user("my-sponsorships-auth-other")

    other_sponsorship =
      create_sponsorship(workspace, other_sponsor, %{
        level: :event,
        event_id: event.id,
        company_name: "Other Sponsor",
        contact_email: other_sponsor.email
      })

    response =
      graphql(
        "query { mySponsorships(first: 20) { count results { id } } }",
        sign_in_token(sponsor)
      )

    assert %{"data" => %{"mySponsorships" => %{"count" => 0, "results" => []}}} = response

    refute other_sponsorship.id in Enum.map(
             response["data"]["mySponsorships"]["results"],
             & &1["id"]
           )

    unauthenticated = graphql("query { mySponsorships(first: 20) { results { id } } }", nil)
    assert Enum.any?(unauthenticated["errors"], &(&1["code"] == "forbidden"))
  end

  defp create_sponsorship(workspace, sponsor, attrs) do
    Sponsorship
    |> Ash.Changeset.for_create(
      :create_sponsorship,
      Map.merge(%{sponsor_user_id: sponsor.id}, attrs),
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: sponsor)
  end

  defp approve(sponsorship, workspace, owner) do
    sponsorship
    |> Ash.Changeset.for_update(:approve_sponsorship, %{}, tenant: workspace.id)
    |> Ash.update!(tenant: workspace.id, actor: owner)
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

  defp graphql(query, nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp graphql(query, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end
end
