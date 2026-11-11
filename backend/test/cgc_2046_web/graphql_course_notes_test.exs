defmodule Cgc2046Web.GraphqlCourseNotesTest do
  @moduledoc """
  Notes GraphQL seam：当前 actor 的查询/创建/编辑/删除；跨用户与课程权限
  统一走服务端错误码。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures

  setup do
    admin = Fixtures.platform_admin("gql-notes")
    workspace = Fixtures.create_workspace(admin)
    course = EventFixtures.create_course(workspace, admin, %{title: "GraphQL Notes"})

    learner = Fixtures.register_user("gql-notes-learner")
    enroll(course, learner)

    outsider = Fixtures.register_user("gql-notes-outsider")
    Fixtures.add_member(workspace, outsider)

    %{course: course, learner: learner, outsider: outsider}
  end

  test "creates, lists, updates and deletes only the current user's notes", ctx do
    token = sign_in_token(ctx.learner)

    created =
      graphql(
        """
        mutation Create($input: CreateCourseNoteInput!) {
          createCourseNote(input: $input) {
            id courseId issueId sourceMaterialId kind text createdAt
          }
        }
        """,
        token,
        %{
          input: %{
            courseId: ctx.course.id,
            issueId: "issue-1",
            sourceMaterialId: "mat-1",
            text: "  GraphQL 笔记  "
          }
        }
      )

    assert %{"data" => %{"createCourseNote" => note}} = created
    assert note["courseId"] == ctx.course.id
    assert note["issueId"] == "issue-1"
    assert note["sourceMaterialId"] == "mat-1"
    assert note["kind"] == "note"
    assert note["text"] == "GraphQL 笔记"
    assert is_binary(note["createdAt"]) and note["createdAt"] != ""

    duplicate =
      graphql(
        """
        mutation Create($input: CreateCourseNoteInput!) {
          createCourseNote(input: $input) { id text }
        }
        """,
        token,
        %{
          input: %{
            courseId: ctx.course.id,
            issueId: "issue-1",
            sourceMaterialId: "mat-1",
            text: "GraphQL 笔记"
          }
        }
      )

    assert %{"data" => %{"createCourseNote" => %{"id" => duplicate_id}}} = duplicate
    assert duplicate_id == note["id"]

    listed =
      graphql(
        """
        query Notes($courseId: ID!) {
          myCourseNotes(courseId: $courseId) { id text kind }
        }
        """,
        token,
        %{courseId: ctx.course.id}
      )

    assert %{"data" => %{"myCourseNotes" => [listed_note]}} = listed
    assert listed_note["id"] == note["id"]

    updated =
      graphql(
        """
        mutation Update($id: ID!, $input: UpdateCourseNoteInput!) {
          updateCourseNote(id: $id, input: $input) { id text }
        }
        """,
        token,
        %{id: note["id"], input: %{text: "更新后"}}
      )

    assert %{"data" => %{"updateCourseNote" => %{"text" => "更新后"}}} = updated

    deleted =
      graphql(
        """
        mutation Delete($id: ID!) { deleteCourseNote(id: $id) }
        """,
        token,
        %{id: note["id"]}
      )

    assert %{"data" => %{"deleteCourseNote" => true}} = deleted

    after_delete =
      graphql(
        """
        query Notes($courseId: ID!) { myCourseNotes(courseId: $courseId) { id } }
        """,
        token,
        %{courseId: ctx.course.id}
      )

    assert %{"data" => %{"myCourseNotes" => []}} = after_delete
  end

  test "rejects creation without course access and hides other users' notes", ctx do
    learner_token = sign_in_token(ctx.learner)
    outsider_token = sign_in_token(ctx.outsider)

    created =
      graphql(
        """
        mutation Create($input: CreateCourseNoteInput!) {
          createCourseNote(input: $input) { id }
        }
        """,
        learner_token,
        %{input: %{courseId: ctx.course.id, issueId: "issue-1", text: "private"}}
      )

    assert %{"data" => %{"createCourseNote" => %{"id" => note_id}}} = created

    outsider_create =
      graphql(
        """
        mutation Create($input: CreateCourseNoteInput!) {
          createCourseNote(input: $input) { id }
        }
        """,
        outsider_token,
        %{input: %{courseId: ctx.course.id, issueId: "issue-1", text: "not allowed"}}
      )

    assert %{"errors" => [%{"code" => "course_not_accessible"}]} = outsider_create

    outsider_list =
      graphql(
        """
        query Notes($courseId: ID!) { myCourseNotes(courseId: $courseId) { id } }
        """,
        outsider_token,
        %{courseId: ctx.course.id}
      )

    assert %{"data" => %{"myCourseNotes" => []}} = outsider_list

    outsider_update =
      graphql(
        """
        mutation Update($id: ID!, $input: UpdateCourseNoteInput!) {
          updateCourseNote(id: $id, input: $input) { id }
        }
        """,
        outsider_token,
        %{id: note_id, input: %{text: "hijack"}}
      )

    assert %{"errors" => [%{"code" => "not_found"}]} = outsider_update
  end

  test "ensureCourseRetro is null until required objectives are mastered", ctx do
    token = sign_in_token(ctx.learner)

    response =
      graphql(
        """
        mutation Retro($courseId: ID!, $issueId: String!) {
          ensureCourseRetro(courseId: $courseId, issueId: $issueId) { id kind }
        }
        """,
        token,
        %{courseId: ctx.course.id, issueId: "issue-1"}
      )

    assert %{"data" => %{"ensureCourseRetro" => nil}} = response
  end

  defp enroll(course, learner) do
    {:ok, enrollment} =
      Enrollment
      |> Ash.Changeset.for_create(:create_enrollment, %{
        course_id: course.id,
        user_id: learner.id
      })
      |> Ash.create(tenant: course.workspace_id, actor: learner)

    enrollment
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

  defp graphql(query, token, variables) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    conn
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end
end
