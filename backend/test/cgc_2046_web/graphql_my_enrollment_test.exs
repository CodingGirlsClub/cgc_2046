defmodule Cgc2046Web.GraphqlMyEnrollmentTest do
  @moduledoc """
  #355 P1-3：`myEnrollment(kind, offeringId)` 查询——详情页「已报名」态数据源。

  - 登录 actor 在目标活动/课程上有活跃报名 → 返回 id + status
    （pending=request 审批中 / confirmed=open 即时确认，活跃集口径与
    MCP discover_offerings.my_enrollment 同源）
  - 匿名 → null 且无 errors（公开详情页可匿名访问，附挂查询不得拖死
    同文档 getEvent/getCourse）
  - 无活跃报名（未报名 / 他人报名 / 已取消）→ null
  - kind 非白名单 → invalid_input
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  defp query(kind, offering_id) do
    """
    query {
      myEnrollment(kind: "#{kind}", offeringId: "#{offering_id}") {
        id
        status
        approvalDeadline
      }
    }
    """
  end

  defp anon(query) do
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

  describe "活跃报名返回" do
    test "request 活动的 pending 报名 → id + pending + 审批截止" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)

      event =
        EventFixtures.create_event(workspace, admin, %{enrollment_policy: :request})

      learner = Fixtures.register_user("gql-my-enr-request")
      enrollment = enroll_on_event(event, learner)
      assert enrollment.status == :pending

      assert %{"data" => %{"myEnrollment" => result}} =
               graphql(query("event", event.id), sign_in_token(learner))

      assert result["id"] == enrollment.id
      assert result["status"] == "pending"
      assert is_binary(result["approvalDeadline"])
    end

    test "open 课程的 confirmed 报名 → id + confirmed" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin)

      learner = Fixtures.register_user("gql-my-enr-open")
      enrollment = enroll_on_course(course, learner)
      assert enrollment.status == :confirmed

      assert %{"data" => %{"myEnrollment" => result}} =
               graphql(query("course", course.id), sign_in_token(learner))

      assert result["id"] == enrollment.id
      assert result["status"] == "confirmed"
    end
  end

  describe "null 语义（附挂信息不阻断详情主读）" do
    test "匿名 → null 且无 errors（与匿名 getEvent 同文档共存）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      response = anon(query("event", event.id))

      assert %{"data" => %{"myEnrollment" => nil}} = response
      refute Map.has_key?(response, "errors")
    end

    test "登录但未报名 → null" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)
      outsider = Fixtures.register_user("gql-my-enr-outsider")

      assert %{"data" => %{"myEnrollment" => nil}} =
               graphql(query("event", event.id), sign_in_token(outsider))
    end

    test "他人报名不可见（本人锚定，按 kind+offering 隔离）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      enrollee = Fixtures.register_user("gql-my-enr-enrollee")
      _enrollment = enroll_on_event(event, enrollee)

      other = Fixtures.register_user("gql-my-enr-other")

      assert %{"data" => %{"myEnrollment" => nil}} =
               graphql(query("event", event.id), sign_in_token(other))
    end

    test "已取消报名 → null（仅活跃集 pending/payment_pending/confirmed）" do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      event = EventFixtures.create_event(workspace, admin)

      learner = Fixtures.register_user("gql-my-enr-cancel")
      enrollment = enroll_on_event(event, learner)

      assert {:ok, _cancelled} =
               enrollment
               |> Ash.Changeset.for_update(:cancel, %{})
               |> Ash.update(tenant: event.workspace_id, actor: learner)

      assert %{"data" => %{"myEnrollment" => nil}} =
               graphql(query("event", event.id), sign_in_token(learner))
    end
  end

  test "kind 非白名单 → invalid_input" do
    learner = Fixtures.register_user("gql-my-enr-bad-kind")

    response = graphql(query("webinar", Ecto.UUID.generate()), sign_in_token(learner))

    assert Enum.any?(response["errors"], &(&1["code"] == "invalid_input"))
  end
end
