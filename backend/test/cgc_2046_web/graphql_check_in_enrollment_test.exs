defmodule Cgc2046Web.GraphqlCheckInEnrollmentTest do
  @moduledoc """
  U5/KTD4 核销 mutation 端到端（R6、R11；AE4 前半）：`checkInEnrollment(eventId, code, method)`。

  走真实 HTTP GraphQL 面（含认证 plug 与 Absinthe 错误序列化），覆盖核销页
  （U10）依赖的三类反馈：成功返回到场事实、已核销 / 码无效进 payload errors
  （前端按 code 查文案）、无权限与匿名分走 Forbidden / unauthorized。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Attendance
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Moderators
  alias Cgc2046.EventsFixtures, as: EventFixtures

  require Ash.Query

  test "主理人（非 workspace 成员）核销成功：返回 enrollmentId / checkedInAt / method" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)
    moderator = Fixtures.register_user("gql-checkin-moderator")
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    enrollment = enroll(event, Fixtures.register_user("gql-checkin-learner"))

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(
               check_in_mutation(event.id, enrollment.check_in_code, "manual"),
               sign_in_token(moderator)
             )

    assert payload["errors"] == []
    assert payload["enrollmentId"] == enrollment.id
    assert payload["method"] == "manual"
    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(payload["checkedInAt"])

    attendance =
      Attendance
      |> Ash.Query.filter(enrollment_id == ^enrollment.id)
      |> Ash.read_one!(authorize?: false)

    assert attendance.operator_id == moderator.id
    assert attendance.method == :manual
  end

  test "再次提交同码：attendance_already_checked_in 进 payload errors（前端显示「已核销」）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)
    moderator = Fixtures.register_user("gql-checkin-again-moderator")
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    enrollment = enroll(event, Fixtures.register_user("gql-checkin-again-learner"))
    token = sign_in_token(moderator)

    assert %{"data" => %{"checkInEnrollment" => %{"errors" => []}}} =
             graphql(check_in_mutation(event.id, enrollment.check_in_code, "scan"), token)

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(check_in_mutation(event.id, enrollment.check_in_code, "scan"), token)

    assert payload["enrollmentId"] == nil
    assert [%{"code" => "attendance_already_checked_in"}] = payload["errors"]
  end

  test "错码：attendance_invalid_code 进 payload errors，不落 Attendance 行" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)
    moderator = Fixtures.register_user("gql-checkin-code-moderator")
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    enrollment = enroll(event, Fixtures.register_user("gql-checkin-code-learner"))

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(check_in_mutation(event.id, "000000", "manual"), sign_in_token(moderator))

    assert [%{"code" => "attendance_invalid_code"}] = payload["errors"]
    assert payload["enrollmentId"] == nil
    assert attendance_count(enrollment.id) == 0
  end

  test "无关用户核销被拒：Forbidden 进 payload errors（无权限）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)
    enrollment = enroll(event, Fixtures.register_user("gql-checkin-denied-learner"))
    outsider = Fixtures.register_user("gql-checkin-outsider")

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(
               check_in_mutation(event.id, enrollment.check_in_code, "manual"),
               sign_in_token(outsider)
             )

    assert [%{"code" => "forbidden"}] = payload["errors"]
    assert attendance_count(enrollment.id) == 0
  end

  test "匿名提交：unauthorized（顶层 error，不进 payload）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner)
    enrollment = enroll(event, Fixtures.register_user("gql-checkin-anon-learner"))

    response = graphql(check_in_mutation(event.id, enrollment.check_in_code, "manual"), nil)

    assert [%{"code" => "unauthorized"} | _] = response["errors"]
    assert attendance_count(enrollment.id) == 0
  end

  # ── 布置 ──

  defp enroll(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create!(tenant: event.workspace_id, actor: user)
  end

  defp check_in_mutation(event_id, code, method) do
    """
    mutation {
      checkInEnrollment(eventId: "#{event_id}", code: "#{code}", method: "#{method}") {
        enrollmentId
        checkedInAt
        method
        errors { message code }
      }
    }
    """
  end

  defp attendance_count(enrollment_id) do
    Attendance
    |> Ash.Query.filter(enrollment_id == ^enrollment_id)
    |> Ash.count!(authorize?: false)
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
