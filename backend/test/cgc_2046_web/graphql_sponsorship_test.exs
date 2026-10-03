defmodule Cgc2046Web.GraphqlSponsorshipTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Sponsorship.Sponsorship

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

  describe "Sponsorship read 行级授权（#709）" do
    setup do
      x = Fixtures.workspace_with_member()
      y = Fixtures.workspace_with_member()
      admin = Fixtures.register_user("sponsorship-read-admin")
      Fixtures.add_member(x.workspace, admin, [:admin])
      sponsor_x = Fixtures.register_user("sponsorship-read-x")
      sponsor_y = Fixtures.register_user("sponsorship-read-y")

      rows_x = sponsorship_pair(x.workspace, x.owner, sponsor_x)
      rows_y = sponsorship_pair(y.workspace, y.owner, sponsor_y)

      %{
        x: x,
        y: y,
        owner: x.owner,
        admin: admin,
        sponsor_x: sponsor_x,
        sponsor_y: sponsor_y,
        rows_x: rows_x,
        rows_y: rows_y
      }
    end

    for role <- [:owner, :admin] do
      test "#{role} 可读本台两级赞助，OR filter 不扩大完整行集", context do
        actor = Map.fetch!(context, unquote(role))
        token = sign_in_token(actor)
        x_id = context.x.workspace.id
        y_id = context.y.workspace.id

        filters = [
          "{workspaceId: {eq: \"#{x_id}\"}}",
          "{or: [{workspaceId: {eq: \"#{x_id}\"}}, " <>
            "{sponsorUserId: {eq: \"#{context.sponsor_y.id}\"}}]}",
          "{or: [{workspaceId: {eq: \"#{x_id}\"}}, {workspaceId: {eq: \"#{y_id}\"}}]}"
        ]

        for filter <- filters do
          assert_sponsorship_rows(sponsorship_list(filter, token), context.rows_x)
        end

        for row <- context.rows_x do
          response = graphql(sponsorship_detail(row.id), token)
          assert response["data"]["getSponsorship"] == %{"id" => row.id, "workspaceId" => x_id}
        end

        for row <- context.rows_y do
          response = graphql(sponsorship_detail(row.id), token)
          assert %{"data" => %{"getSponsorship" => nil}} = response
        end
      end
    end

    test "无管理角色成员不能读取本人以外的赞助", context do
      for roles <- [[], [:tutor], [:volunteer], [:learner]] do
        member = Fixtures.register_user("sponsorship-read-member")
        Fixtures.add_member(context.x.workspace, member, roles)

        assert_sponsorship_rows(
          sponsorship_list(workspace_or_filter(context), sign_in_token(member)),
          []
        )
      end
    end

    test "无成员资格的 sponsor 可跨工作台读本人行，但不可读其他 sponsor", context do
      own_y = sponsorship_pair(context.y.workspace, context.y.owner, context.sponsor_x)

      assert_sponsorship_rows(
        sponsorship_list(workspace_or_filter(context), sign_in_token(context.sponsor_x)),
        context.rows_x ++ own_y
      )
    end

    test "管理读面与外台 self-read 取并集，不放行外台第三人的赞助", context do
      own_y =
        create_sponsorship(context.y.workspace, context.owner, %{
          level: :workspace,
          target_workspace_id: context.y.workspace.id
        })

      assert_sponsorship_rows(
        sponsorship_list(workspace_or_filter(context), sign_in_token(context.owner)),
        context.rows_x ++ [own_y]
      )
    end

    test "非成员 PlatformAdmin 保留跨工作台读取 bypass", context do
      platform_admin = Fixtures.platform_admin("sponsorship-read-platform")

      assert_sponsorship_rows(
        sponsorship_list(workspace_or_filter(context), sign_in_token(platform_admin)),
        context.rows_x ++ context.rows_y
      )
    end

    test "匿名读取 fail-closed，不返回赞助数据", context do
      response = sponsorship_list(workspace_or_filter(context), nil)

      assert %{"data" => %{"sponsorships" => nil}, "errors" => errors} = response
      assert Enum.any?(errors, &(&1["code"] == "forbidden"))
    end
  end

  defp sponsorship_pair(workspace, owner, sponsor) do
    event = EventFixtures.create_event(workspace, owner)

    [
      create_sponsorship(workspace, sponsor, %{level: :event, event_id: event.id}),
      create_sponsorship(workspace, sponsor, %{
        level: :workspace,
        target_workspace_id: workspace.id
      })
    ]
  end

  defp create_sponsorship(workspace, sponsor, attrs) do
    attrs =
      Map.merge(
        %{
          sponsor_user_id: sponsor.id,
          company_name: "Read isolation sponsor",
          contact_email: sponsor.email,
          amount: if(attrs.level == :event, do: 10_000, else: 20_000)
        },
        attrs
      )

    Sponsorship
    |> Ash.Changeset.for_create(:create_sponsorship, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: sponsor)
  end

  defp workspace_or_filter(context) do
    "{or: [{workspaceId: {eq: \"#{context.x.workspace.id}\"}}, " <>
      "{workspaceId: {eq: \"#{context.y.workspace.id}\"}}]}"
  end

  defp sponsorship_list(filter, token) do
    graphql(
      "query { sponsorships(first: 250, filter: #{filter}) " <>
        "{ results { id workspaceId sponsorUserId amount contactEmail } } }",
      token
    )
  end

  defp sponsorship_detail(id) do
    "query { getSponsorship(id: \"#{id}\") { id workspaceId } }"
  end

  defp assert_sponsorship_rows(response, expected) do
    assert %{"data" => %{"sponsorships" => %{"results" => rows}}} = response
    refute Map.has_key?(response, "errors")
    assert MapSet.new(rows, & &1["id"]) == MapSet.new(expected, & &1.id)
    assert MapSet.new(rows, & &1["workspaceId"]) == MapSet.new(expected, & &1.workspace_id)
    assert length(rows) == length(expected)
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
