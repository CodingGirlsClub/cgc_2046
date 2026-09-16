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
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
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

    # 免费场报名无押金单：核销不产生退款，结果不得宣称已发起（前端据此不出押金文案）
    assert payload["depositRefund"] == nil
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
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
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
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
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

  test "押金单已付：核销返回 depositRefund=refunding（前端据此显示押金退款文案）" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner, deposit_attrs())
    moderator = Fixtures.register_user("gql-checkin-deposit-moderator")
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    learner = Fixtures.register_user("gql-checkin-deposit-learner")
    enrollment = enroll(event, learner)
    paid_deposit_order(enrollment, workspace, learner)

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(
               check_in_mutation(event.id, enrollment.check_in_code, "manual"),
               sign_in_token(moderator)
             )

    assert payload["errors"] == []
    assert payload["depositRefund"] == "refunding"
  end

  test "押金已按未到场结算：核销被拒（deposit_already_forfeited），不落 Attendance" do
    %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner, deposit_attrs())
    moderator = Fixtures.register_user("gql-checkin-forfeit-moderator")
    # 成员前提（#558）：主理人须为本工作台成员
    Fixtures.add_member(workspace, moderator, [:learner])
    {:ok, _} = Moderators.assign(event.id, workspace.id, moderator.id, owner)
    learner = Fixtures.register_user("gql-checkin-forfeit-learner")
    enrollment = enroll(event, learner)
    order = paid_deposit_order(enrollment, workspace, learner)

    {:ok, _} =
      order
      |> Ash.Changeset.for_update(:forfeit, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    assert %{"data" => %{"checkInEnrollment" => payload}} =
             graphql(
               check_in_mutation(event.id, enrollment.check_in_code, "manual"),
               sign_in_token(moderator)
             )

    assert [%{"code" => "deposit_already_forfeited"}] = payload["errors"]
    assert payload["depositRefund"] == nil
    assert attendance_count(enrollment.id) == 0
  end

  # ── 布置 ──

  defp enroll(event, user) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: user.id})
    |> Ash.create!(tenant: event.workspace_id, actor: user)
  end

  defp deposit_attrs do
    %{
      deposit_enabled: true,
      deposit_amount_cents: 6900,
      ends_at: EventFixtures.days_from_now(8)
    }
  end

  # 已付押金单：走真实下单链（金额源=报名快照）后 mark_paid
  defp paid_deposit_order(enrollment, workspace, learner) do
    {:ok, order} =
      Cgc2046.Payments.Order
      |> Ash.Changeset.for_create(:create_for_enrollment, %{
        enrollment_id: enrollment.id,
        provider: :wechat_native
      })
      |> Ash.create(tenant: workspace.id, actor: learner)

    {:ok, paid} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: "txn-" <> order.out_trade_no})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    # 押金场报名在支付前是 payment_pending；落账 worker 才是 confirmed 的驱动者
    # （本用例只关心核销结果字段，故直接走同一内部动作，不重放渠道回调）
    {:ok, _confirmed} =
      enrollment
      |> Ash.Changeset.for_update(:settle_paid, %{})
      |> Ash.update(tenant: workspace.id, authorize?: false)

    paid
  end

  defp check_in_mutation(event_id, code, method) do
    """
    mutation {
      checkInEnrollment(eventId: "#{event_id}", code: "#{code}", method: "#{method}") {
        enrollmentId
        checkedInAt
        method
        depositRefund
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
