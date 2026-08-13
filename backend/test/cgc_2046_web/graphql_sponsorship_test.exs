defmodule Cgc2046Web.GraphqlSponsorshipTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @tier %{
    "id" => "9d2f7c80-0000-4000-8000-0000000000ab",
    "name" => "冠名",
    "amount_suggestion" => 10_000,
    "benefits" => ["logo 展示位"],
    "exclusive" => true
  }

  # E-8 审批控制台接入：sponsorship pending 出现在 myPendingApprovals，
  # /approvals kind dispatch 的 approve/reject E2E 状态转换正确。
  test "E2E：意向提交 → pending 出现在控制台 → approve → active；reject 带 reason → rejected" do
    admin = Fixtures.platform_admin("sponsor-console-admin")
    workspace = Fixtures.create_workspace(admin, %{sponsorship_tiers: [@tier]})
    owner = Fixtures.register_user("sponsor-console-owner")
    Fixtures.add_member(workspace, owner, [:owner])
    event = EventFixtures.create_event(workspace, owner, %{sponsorship_tiers: [@tier]})

    sponsor = Fixtures.register_user("sponsor-console-sponsor")
    owner_token = sign_in_token(owner)
    sponsor_token = sign_in_token(sponsor)

    # 1. 意向提交（登录后的赞助方）
    create_response =
      graphql(
        """
        mutation {
          createSponsorship(input: {
            level: "event"
            eventId: "#{event.id}"
            sponsorUserId: "#{sponsor.id}"
            companyName: "Acme 冠名"
            contactEmail: "#{sponsor.email}"
            tierId: "#{@tier["id"]}"
            amount: 10000
          }) {
            result { id status level tierName approvalDeadline workspaceId }
            errors { message }
          }
        }
        """,
        sponsor_token
      )

    assert %{
             "data" => %{
               "createSponsorship" => %{
                 "result" => %{
                   "status" => "pending",
                   "level" => "event",
                   "tierName" => "冠名",
                   "workspaceId" => workspace_id
                 },
                 "errors" => []
               }
             }
           } = create_response

    assert workspace_id == workspace.id

    sponsorship_id = create_response["data"]["createSponsorship"]["result"]["id"]

    # 2. 控制台聚合出现 sponsorship 行（requester/context 摘要）
    approvals_response =
      graphql(
        """
        query {
          myPendingApprovals {
            id
            kind
            status
            requesterName
            workspaceName
            contextTitle
            companyName
            tierName
            level
          }
        }
        """,
        owner_token
      )

    assert %{"data" => %{"myPendingApprovals" => [row]}} = approvals_response
    assert row["kind"] == "sponsorship"
    assert row["status"] == "pending"
    assert row["requesterName"] == "Acme 冠名"
    assert row["companyName"] == "Acme 冠名"
    assert row["tierName"] == "冠名"
    assert row["contextTitle"] == event.title
    assert row["workspaceName"] == workspace.name

    # 3. approve → active（审批两段式状态转换）
    approve_response =
      graphql(
        """
        mutation {
          approveSponsorship(id: "#{sponsorship_id}") {
            result { id status }
            errors { message }
          }
        }
        """,
        owner_token
      )

    assert %{"data" => %{"approveSponsorship" => %{"result" => %{"status" => "active"}}}} =
             approve_response

    # 4. 第二个赞助 → reject 带 reason → rejected 落审计
    sponsor2 = Fixtures.register_user("sponsor-console-reject")

    create2 =
      graphql(
        """
        mutation {
          createSponsorship(input: {
            level: "event"
            eventId: "#{event.id}"
            sponsorUserId: "#{sponsor2.id}"
            companyName: "Beta 标准"
            contactEmail: "#{sponsor2.email}"
          }) {
            result { id }
          }
        }
        """,
        sign_in_token(sponsor2)
      )

    id2 = create2["data"]["createSponsorship"]["result"]["id"]

    reject_response =
      graphql(
        """
        mutation {
          rejectSponsorship(id: "#{id2}", input: {rejectionReason: "物料不符合"}) {
            result { id status rejectionReason }
            errors { message }
          }
        }
        """,
        owner_token
      )

    assert %{
             "data" => %{
               "rejectSponsorship" => %{
                 "result" => %{"status" => "rejected", "rejectionReason" => "物料不符合"}
               }
             }
           } = reject_response
  end

  test "Workspace 级：Admin 经 HTTP approve 被拒（拍板 #4 仅 Owner）" do
    admin = Fixtures.platform_admin("console-ws-admin-platform")
    workspace = Fixtures.create_workspace(admin)
    owner = Fixtures.register_user("console-ws-owner")
    Fixtures.add_member(workspace, owner, [:owner])
    admin_member = Fixtures.register_user("console-ws-admin")
    Fixtures.add_member(workspace, admin_member, [:admin])

    sponsor = Fixtures.register_user("console-ws-sponsor")

    create_response =
      graphql(
        """
        mutation {
          createSponsorship(input: {
            level: "workspace"
            targetWorkspaceId: "#{workspace.id}"
            sponsorUserId: "#{sponsor.id}"
            companyName: "长期伙伴"
            contactEmail: "#{sponsor.email}"
          }) {
            result { id }
          }
        }
        """,
        sign_in_token(sponsor)
      )

    sponsorship_id = create_response["data"]["createSponsorship"]["result"]["id"]

    response =
      graphql(
        """
        mutation {
          approveSponsorship(id: "#{sponsorship_id}") {
            result { id status }
            errors { message }
          }
        }
        """,
        sign_in_token(admin_member)
      )

    assert %{"data" => %{"approveSponsorship" => %{"result" => nil, "errors" => errors}}} =
             response

    assert Enum.map_join(errors, " ", & &1["message"]) =~ "forbidden"
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
