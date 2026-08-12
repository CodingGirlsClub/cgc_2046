defmodule Cgc2046Web.GraphqlCreateEnrollmentTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.InviteBatch
  alias Cgc2046.EventsFixtures, as: EventFixtures

  # #104：GraphQL pipeline 不注入 tenant，createEnrollment 必须从目标派生 tenant，
  # 三种 enrollment_policy 经真实 HTTP 入口各走通一次（此前恒报 target_tenant_mismatch）。

  test "open 活动：HTTP mutation 立即 confirmed 并占用名额，满员后第二人报 capacity" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{capacity: 1, enrollment_policy: :open})
    learner = Fixtures.register_user("gql-enroll-open")

    response = graphql(create_mutation(event, learner), sign_in_token(learner))

    assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
             response

    assert result["status"] == "confirmed"
    assert result["capacitySeq"] == 1
    assert result["workspaceId"] == workspace.id
    assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1

    second = Fixtures.register_user("gql-enroll-open-full")

    assert %{"data" => %{"createEnrollment" => %{"result" => nil, "errors" => errors}}} =
             graphql(create_mutation(event, second), sign_in_token(second))

    assert Enum.map_join(errors, " ", & &1["message"]) =~ "capacity"
    assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1
  end

  test "request 活动：HTTP mutation 先 pending 且带 approvalDeadline，不占名额" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{capacity: 1, enrollment_policy: :request})

    learner = Fixtures.register_user("gql-enroll-request")

    response = graphql(create_mutation(event, learner), sign_in_token(learner))

    assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
             response

    assert result["status"] == "pending"
    refute is_nil(result["approvalDeadline"])
    assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 0
  end

  test "invite_only 活动：HTTP mutation 带 inviteCode 立即 confirmed 并扣减批次配额" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        capacity: 1,
        enrollment_policy: :invite_only
      })

    batch =
      InviteBatch
      |> Ash.Changeset.for_create(:create, %{
        event_id: event.id,
        invite_code: "CAMPUS_A",
        quota: 1
      })
      |> Ash.create!(tenant: workspace.id, actor: admin)

    learner = Fixtures.register_user("gql-enroll-invite")

    response =
      graphql(create_mutation(event, learner, invite_code: "CAMPUS_A"), sign_in_token(learner))

    assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
             response

    assert result["status"] == "confirmed"
    assert result["inviteBatchId"] == batch.id
    assert Ash.get!(InviteBatch, batch.id, authorize?: false).remaining_quota == 0
  end

  defp create_mutation(event, user, extra \\ []) do
    invite_code_input =
      case Keyword.get(extra, :invite_code) do
        nil -> ""
        code -> ", inviteCode: \"#{code}\""
      end

    """
    mutation {
      createEnrollment(input: {eventId: "#{event.id}", userId: "#{user.id}"#{invite_code_input}}) {
        result { id status capacitySeq workspaceId inviteBatchId approvalDeadline }
        errors { message }
      }
    }
    """
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
