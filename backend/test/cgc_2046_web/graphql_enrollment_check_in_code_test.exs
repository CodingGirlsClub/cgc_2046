defmodule Cgc2046Web.GraphqlEnrollmentCheckInCodeTest do
  @moduledoc """
  U4/KTD5 核销码暴露门控（R11）：`checkInCode` 只对「actor 即报名人且报名
  confirmed」返回，其余（本人未确认 / 他人 / Owner·Admin / PlatformAdmin）
  一律 null。

  - `myEnrollment` 走 `my_enrollment_payload/1` 白名单 map 形态
  - `myEnrollments` / `enrollments` 走 Ash record 形态
    （Enrollment read policy 允许 Owner/Admin/PlatformAdmin 读列表，字段级
    resolve 是唯一闸——门控不得依赖 policy）
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @code_pattern ~r/^\d{6}$/

  test "押金场：payment_pending 报名 checkInCode 为 null，落账 confirmed 后返回同码" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)

    event =
      EventFixtures.create_event(workspace, admin, %{
        deposit_enabled: true,
        deposit_amount_cents: 6900,
        ends_at: EventFixtures.days_from_now(8)
      })

    learner = Fixtures.register_user("gql-code-deposit")
    token = sign_in_token(learner)

    enrollment = enroll_on_event(event, learner)
    assert enrollment.status == :payment_pending
    assert enrollment.check_in_code =~ @code_pattern

    # 待支付：本人可见、码不可见（myEnrollment 白名单 payload 路径 + 列表 record 路径）
    assert %{
             "data" => %{
               "myEnrollment" => %{
                 "id" => enrollment_id,
                 "status" => "payment_pending",
                 "checkInCode" => nil
               }
             }
           } = graphql(my_enrollment_query("event", event.id), token)

    assert enrollment_id == enrollment.id

    assert %{"data" => %{"myEnrollments" => %{"results" => [%{"checkInCode" => nil}]}}} =
             graphql(my_enrollments_query(), token)

    # 落账 confirmed：同一行上的码出示（生成时点=create 单写点，确认不重生成）
    {:ok, _} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    assert %{
             "data" => %{
               "myEnrollment" => %{"status" => "confirmed", "checkInCode" => check_in_code}
             }
           } = graphql(my_enrollment_query("event", event.id), token)

    assert check_in_code == enrollment.check_in_code
    assert check_in_code =~ @code_pattern

    assert %{"data" => %{"myEnrollments" => %{"results" => [%{"checkInCode" => listed}]}}} =
             graphql(my_enrollments_query(), token)

    assert listed == enrollment.check_in_code
  end

  test "course 报名（码恒为 null）在 confirmed 态返回 null 而非报错" do
    admin = Fixtures.platform_admin()
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin)
    learner = Fixtures.register_user("gql-code-course")

    assert %{status: :confirmed, check_in_code: nil} = enroll_on_course(course, learner)

    assert %{"data" => %{"myEnrollment" => %{"status" => "confirmed", "checkInCode" => nil}}} =
             graphql(my_enrollment_query("course", course.id), sign_in_token(learner))
  end

  test "本人列表返回码；同 workspace Owner/Admin 与 PlatformAdmin 列表该字段为 null" do
    admin = Fixtures.platform_admin("gql-code-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    owner = Fixtures.register_user("gql-code-owner")
    Fixtures.add_member(workspace, owner, [:owner])

    learner = Fixtures.register_user("gql-code-self")
    enrollment = enroll_on_event(event, learner)
    assert enrollment.status == :confirmed
    assert enrollment.check_in_code =~ @code_pattern

    # 本人 myEnrollments（Ash record 形态）→ 返回码
    # （查询刻意不请求 userId：出示门控的隐性依赖必须由资源级补选承载）
    assert %{"data" => %{"myEnrollments" => %{"results" => [row]}}} =
             graphql(my_enrollments_query(), sign_in_token(learner))

    assert row["id"] == enrollment.id
    assert row["checkInCode"] == enrollment.check_in_code

    # Owner/Admin 读得到该行（read policy 放行），字段级 resolve 置 null
    assert %{"data" => %{"enrollments" => %{"results" => [owner_row]}}} =
             graphql(workspace_enrollments_query(workspace.id), sign_in_token(owner))

    assert owner_row["id"] == enrollment.id
    assert owner_row["userId"] == learner.id
    assert owner_row["checkInCode"] == nil

    # PlatformAdmin 同理
    assert %{"data" => %{"enrollments" => %{"results" => [admin_row]}}} =
             graphql(workspace_enrollments_query(workspace.id), sign_in_token(admin))

    assert admin_row["id"] == enrollment.id
    assert admin_row["checkInCode"] == nil
  end

  # ── 布置 ──

  defp enroll_on_event(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create!(tenant: event.workspace_id, actor: user)
  end

  defp enroll_on_course(course, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{course_id: course.id, user_id: user.id})
    |> Ash.create!(tenant: course.workspace_id, actor: user)
  end

  defp my_enrollment_query(kind, offering_id) do
    """
    query {
      myEnrollment(kind: "#{kind}", offeringId: "#{offering_id}") {
        id
        status
        checkInCode
      }
    }
    """
  end

  defp my_enrollments_query do
    """
    query {
      myEnrollments(first: 10) {
        results { id status checkInCode }
      }
    }
    """
  end

  defp workspace_enrollments_query(workspace_id) do
    """
    query {
      enrollments(first: 10, filter: { workspaceId: { eq: "#{workspace_id}" } }) {
        results { id userId status checkInCode }
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
