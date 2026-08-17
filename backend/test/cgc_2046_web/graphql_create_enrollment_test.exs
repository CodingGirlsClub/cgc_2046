defmodule Cgc2046Web.GraphqlCreateEnrollmentTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
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

  describe "G1 visibility 校验（E-5 #50 安全洞修复）" do
    test "非成员对 workspace-only 活动报名 → 拒绝（not_found 语义，不泄露存在性）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})
      outsider = Fixtures.register_user("gql-enroll-vis-outside")

      response = graphql(create_mutation(event, outsider), sign_in_token(outsider))

      assert %{"data" => %{"createEnrollment" => %{"result" => nil, "errors" => errors}}} =
               response

      assert Enum.map_join(errors, " ", & &1["message"]) =~ "not open or registration"
      # 未落库（不泄露目标存在性）
      assert Ash.read!(Enrollment, authorize?: false) == []
    end

    test "非成员对 public 活动报名 → 正常（visibility 不影响 public 报名）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :public})
      outsider = Fixtures.register_user("gql-enroll-vis-outside-pub")

      response = graphql(create_mutation(event, outsider), sign_in_token(outsider))

      assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
               response

      assert result["status"] == "confirmed"
    end

    test "成员对 workspace-only 活动报名 → 正常（成员路径 D2）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin, %{visibility: :workspace})
      member = Fixtures.register_user("gql-enroll-vis-member")
      Fixtures.add_member(workspace, member)

      response = graphql(create_mutation(event, member), sign_in_token(member))

      assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
               response

      assert result["status"] == "confirmed"
      assert result["workspaceId"] == workspace.id
    end
  end

  test "PlatformAdmin 本人不能经 HTTP createEnrollment 报名" do
    admin = Fixtures.platform_admin("gql-enroll-platform-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :open})

    response = graphql(create_mutation(event, admin), sign_in_token(admin))

    assert %{"data" => %{"createEnrollment" => %{"result" => nil, "errors" => errors}}} =
             response

    assert Enum.any?(errors, &(&1["message"] == "forbidden"))
  end

  test "PlatformAdmin 非成员不能确认或拒绝报名，Owner 路径仍可用" do
    admin = Fixtures.platform_admin("gql-enroll-approval-admin")
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request, capacity: 10})

    confirm_id = create_pending_enrollment(event, "gql-enroll-approval-confirm-owner")
    reject_id = create_pending_enrollment(event, "gql-enroll-approval-reject-owner")
    forbidden_confirm_id = create_pending_enrollment(event, "gql-enroll-approval-confirm-admin")
    forbidden_reject_id = create_pending_enrollment(event, "gql-enroll-approval-reject-admin")
    owner_token = sign_in_token(admin)

    assert %{
             "data" => %{
               "confirmEnrollment" => %{
                 "result" => %{"id" => ^confirm_id, "status" => "confirmed"},
                 "errors" => []
               }
             }
           } =
             graphql(
               """
               mutation {
                 confirmEnrollment(id: "#{confirm_id}") {
                   result { id status }
                   errors { message }
                 }
               }
               """,
               owner_token
             )

    assert %{
             "data" => %{
               "rejectEnrollment" => %{
                 "result" => %{"id" => ^reject_id, "status" => "rejected"},
                 "errors" => []
               }
             }
           } =
             graphql(
               """
               mutation {
                 rejectEnrollment(id: "#{reject_id}", input: { rejectionReason: "不符合条件" }) {
                   result { id status }
                   errors { message }
                 }
               }
               """,
               owner_token
             )

    Fixtures.remove_membership(workspace, admin)
    admin_token = sign_in_token(admin)

    assert %{
             "data" => %{
               "confirmEnrollment" => %{"result" => nil, "errors" => confirm_errors}
             }
           } =
             graphql(
               """
               mutation {
                 confirmEnrollment(id: "#{forbidden_confirm_id}") {
                   result { id status }
                   errors { message }
                 }
               }
               """,
               admin_token
             )

    assert Enum.any?(confirm_errors, &(&1["message"] =~ "forbidden"))

    assert %{
             "data" => %{
               "rejectEnrollment" => %{"result" => nil, "errors" => reject_errors}
             }
           } =
             graphql(
               """
               mutation {
                 rejectEnrollment(
                   id: "#{forbidden_reject_id}"
                   input: { rejectionReason: "不符合条件" }
                 ) {
                   result { id status }
                   errors { message }
                 }
               }
               """,
               admin_token
             )

    assert Enum.any?(reject_errors, &(&1["message"] =~ "forbidden"))
  end

  defp create_pending_enrollment(event, prefix) do
    learner = Fixtures.register_user(prefix)

    assert %{
             "data" => %{
               "createEnrollment" => %{
                 "result" => %{"id" => id, "status" => "pending"},
                 "errors" => []
               }
             }
           } =
             graphql(create_mutation(event, learner), sign_in_token(learner))

    id
  end

  # ── 收费报名（U3）：HTTP 面进入 payment_pending ──────────────────────────────

  test "收费 open 活动：HTTP mutation 占位后进 payment_pending（R5）" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    tier_id = Ecto.UUID.generate()

    event =
      EventFixtures.create_event(workspace, admin, %{
        capacity: 1,
        pricing_enabled: true,
        price_tiers: [%{"id" => tier_id, "name" => "标准", "amount_cents" => 19_900}]
      })

    learner = Fixtures.register_user("gql-enroll-paid")

    response = graphql(create_mutation(event, learner, tier_id: tier_id), sign_in_token(learner))

    assert %{"data" => %{"createEnrollment" => %{"result" => result, "errors" => []}}} =
             response

    assert result["status"] == "payment_pending"
    assert result["capacitySeq"] == 1
    assert Ash.get!(event.__struct__, event.id, authorize?: false).confirmed_count == 1
  end

  defp create_mutation(event, user, extra \\ []) do
    invite_code_input =
      case Keyword.get(extra, :invite_code) do
        nil -> ""
        code -> ", inviteCode: \"#{code}\""
      end

    tier_id_input =
      case Keyword.get(extra, :tier_id) do
        nil -> ""
        tier_id -> ", tierId: \"#{tier_id}\""
      end

    """
    mutation {
      createEnrollment(input: {eventId: "#{event.id}", userId: "#{user.id}"#{invite_code_input}#{tier_id_input}}) {
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
