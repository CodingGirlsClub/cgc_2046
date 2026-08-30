defmodule Cgc2046Web.GraphqlEnrollmentMyQueryTest do
  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  test "本人可跨工作台分页读取报名并补齐目标标题" do
    admin = Fixtures.platform_admin("my-enrollments-admin")
    workspace_a = Fixtures.create_workspace(admin, %{name: "报名工作台 A"})
    workspace_b = Fixtures.create_workspace(admin, %{name: "报名工作台 B"})
    learner = Fixtures.register_user("my-enrollments-learner")
    other_learner = Fixtures.register_user("my-enrollments-other")

    event_a = EventFixtures.create_event(workspace_a, admin, %{title: "活动 A"})
    course_a = EventFixtures.create_course(workspace_a, admin, %{title: "课程 A"})
    event_b = EventFixtures.create_event(workspace_b, admin, %{title: "活动 B"})

    event_pending =
      EventFixtures.create_event(workspace_a, admin, %{
        title: "待审批活动",
        enrollment_policy: :request
      })

    snapshot_enrollment =
      create_enrollment(workspace_a, learner, %{
        event_id: event_a.id,
        submission_payload: %{"targetTitle" => "快照标题"}
      })

    course_enrollment = create_enrollment(workspace_a, learner, %{course_id: course_a.id})
    cross_workspace_enrollment = create_enrollment(workspace_b, learner, %{event_id: event_b.id})
    pending_enrollment = create_enrollment(workspace_a, learner, %{event_id: event_pending.id})

    _other_enrollment =
      create_enrollment(workspace_a, other_learner, %{event_id: event_pending.id})

    response =
      graphql(
        """
        query {
          myEnrollments(first: 2, sort: [{field: INSERTED_AT, order: ASC}]) {
            count
            results {
              id
              status
              eventId
              courseId
              targetTitle
              insertedAt
            }
            endKeyset
          }
        }
        """,
        sign_in_token(learner)
      )

    assert %{
             "data" => %{
               "myEnrollments" => %{
                 "count" => 4,
                 "results" => first_page,
                 "endKeyset" => end_keyset
               }
             }
           } = response

    assert is_binary(end_keyset)
    assert length(first_page) == 2

    assert Enum.all?(
             first_page,
             &(&1["id"] in [
                 snapshot_enrollment.id,
                 course_enrollment.id,
                 cross_workspace_enrollment.id,
                 pending_enrollment.id
               ])
           )

    second_response =
      graphql(
        """
        query {
          myEnrollments(first: 2, after: "#{end_keyset}", sort: [{field: INSERTED_AT, order: ASC}]) {
            results { id status targetTitle }
          }
        }
        """,
        sign_in_token(learner)
      )

    assert %{"data" => %{"myEnrollments" => %{"results" => second_page}}} = second_response
    assert length(second_page) == 2
    assert MapSet.size(MapSet.new(first_page, & &1["id"])) == 2
    assert MapSet.size(MapSet.new(second_page, & &1["id"])) == 2

    assert MapSet.disjoint?(
             MapSet.new(first_page, & &1["id"]),
             MapSet.new(second_page, & &1["id"])
           )

    all_response =
      graphql(
        """
        query {
          myEnrollments(first: 20, sort: [{field: INSERTED_AT, order: ASC}]) {
            results { id status targetTitle }
          }
        }
        """,
        sign_in_token(learner)
      )

    assert %{"data" => %{"myEnrollments" => %{"results" => rows}}} = all_response
    assert Enum.find(rows, &(&1["id"] == snapshot_enrollment.id))["targetTitle"] == "快照标题"
    assert Enum.find(rows, &(&1["id"] == course_enrollment.id))["targetTitle"] == "课程 A"
    assert Enum.find(rows, &(&1["id"] == cross_workspace_enrollment.id))["targetTitle"] == "活动 B"
    assert Enum.find(rows, &(&1["id"] == pending_enrollment.id))["status"] == "pending"
  end

  test "actor filter prevents another user's records and unauthenticated reads" do
    admin = Fixtures.platform_admin("my-enrollments-auth-admin")
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("my-enrollments-auth-learner")
    other_learner = Fixtures.register_user("my-enrollments-auth-other")
    event = EventFixtures.create_event(workspace, admin)
    other_enrollment = create_enrollment(workspace, other_learner, %{event_id: event.id})

    response =
      graphql(
        """
        query { myEnrollments(first: 20) { count results { id } } }
        """,
        sign_in_token(learner)
      )

    assert %{"data" => %{"myEnrollments" => %{"count" => 0, "results" => []}}} = response

    assert other_enrollment.id not in Enum.map(
             response["data"]["myEnrollments"]["results"],
             & &1["id"]
           )

    unauthenticated = graphql("query { myEnrollments(first: 20) { results { id } } }", nil)
    assert Enum.any?(unauthenticated["errors"], &(&1["code"] == "forbidden"))
  end

  test "cancel 不能操作其他用户的报名" do
    admin = Fixtures.platform_admin("my-enrollments-cancel-admin")
    workspace = Fixtures.create_workspace(admin)
    learner = Fixtures.register_user("my-enrollments-cancel-learner")
    other_learner = Fixtures.register_user("my-enrollments-cancel-other")
    event = EventFixtures.create_event(workspace, admin)
    other_enrollment = create_enrollment(workspace, other_learner, %{event_id: event.id})

    response =
      graphql(
        """
        mutation {
          cancelEnrollment(id: "#{other_enrollment.id}") {
            result { id status }
            errors { code message }
          }
        }
        """,
        sign_in_token(learner)
      )

    assert %{"data" => %{"cancelEnrollment" => %{"result" => nil, "errors" => errors}}} = response
    assert Enum.any?(errors, &(&1["code"] in ["forbidden", "unauthorized", "not_found"]))
  end

  test "PlatformAdmin 本人不能取消自己的报名" do
    admin = Fixtures.platform_admin("my-enrollments-platform-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin)

    enrollment =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: admin.id})
      |> Ash.create!(tenant: workspace.id, actor: admin, authorize?: false)

    response =
      graphql(
        """
        mutation {
          cancelEnrollment(id: "#{enrollment.id}") {
            result { id status }
            errors { code message }
          }
        }
        """,
        sign_in_token(admin)
      )

    assert %{"data" => %{"cancelEnrollment" => %{"result" => nil, "errors" => errors}}} =
             response

    assert Enum.any?(errors, &(&1["code"] in ["forbidden", "unauthorized"]))
  end

  test "Enrollment output type does not expose submission payload" do
    # #81：test env 已关闭 introspection（VULN-001），契约检查改走 schema 内部结构，
    # 不依赖 __type 查询——与 prod 行为一致。
    type = Absinthe.Schema.lookup_type(Cgc2046Web.GraphqlSchema, "Enrollment")
    field_names = type.fields |> Map.keys() |> Enum.map(&to_string/1)

    refute "submissionPayload" in field_names
  end

  defp create_enrollment(workspace, user, attrs) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, Map.merge(%{user_id: user.id}, attrs),
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: user)
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
