defmodule Cgc2046Web.GraphqlInviteBatchTest do
  use Cgc2046Web.ConnCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.InviteBatch
  alias Cgc2046.EventsFixtures, as: EventFixtures

  test "Owner 与 Admin 经 HTTP 创建成功，服务端派生 workspace_id 且公开 insertedAt" do
    %{owner: owner, admin: admin, workspace: workspace} = managed_workspace()
    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :invite_only})
    owner_token = sign_in_token(owner)
    admin_token = sign_in_token(admin)

    owner_response =
      graphql(create_mutation(:event, event.id, "OWNER_CODE", 3, "owner remark"), owner_token)

    assert %{"data" => %{"createInviteBatch" => %{"result" => owner_result, "errors" => []}}} =
             owner_response

    assert owner_result["workspaceId"] == workspace.id
    assert owner_result["eventId"] == event.id
    assert owner_result["remainingQuota"] == 3
    assert is_binary(owner_result["insertedAt"])

    owner_batch = Ash.get!(InviteBatch, owner_result["id"], authorize?: false)
    assert owner_batch.workspace_id == workspace.id

    admin_response =
      graphql(create_mutation(:event, event.id, "ADMIN_CODE", 2), admin_token)

    assert %{"data" => %{"createInviteBatch" => %{"result" => admin_result, "errors" => []}}} =
             admin_response

    assert admin_result["workspaceId"] == workspace.id

    assert Ash.get!(InviteBatch, admin_result["id"], authorize?: false).workspace_id ==
             workspace.id
  end

  test "platform admin 经 HTTP 创建批次码仍按既有 policy 放行" do
    admin = Fixtures.platform_admin("gql-invite-platform-admin")
    workspace = Fixtures.create_workspace(admin)
    event = EventFixtures.create_event(workspace, admin, %{enrollment_policy: :invite_only})

    response =
      graphql(create_mutation(:event, event.id, "PLATFORM_CODE", 1), sign_in_token(admin))

    assert %{"data" => %{"createInviteBatch" => %{"result" => result, "errors" => []}}} =
             response

    assert result["workspaceId"] == workspace.id
  end

  test "跨租户目标经 HTTP 创建被拒绝且不落库" do
    first = managed_workspace()
    second = managed_workspace()

    event =
      EventFixtures.create_event(second.workspace, second.owner, %{
        enrollment_policy: :invite_only
      })

    response =
      graphql(
        create_mutation(:event, event.id, "CROSS_TENANT", 1),
        sign_in_token(first.owner)
      )

    assert %{"data" => %{"createInviteBatch" => %{"result" => nil, "errors" => errors}}} =
             response

    assert errors != []

    # #242：断言按本测试 event_id 隔离，避免共享表残留污染全局空断言
    assert InviteBatch
           |> Ash.Query.filter(event_id == ^event.id)
           |> Ash.read!(authorize?: false) == []
  end

  test "invite_code 全局唯一冲突经 HTTP 返回错误" do
    %{owner: owner, workspace: workspace} = managed_workspace()
    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :invite_only})
    course = EventFixtures.create_course(workspace, owner, %{enrollment_policy: :invite_only})
    token = sign_in_token(owner)

    assert %{"data" => %{"createInviteBatch" => %{"result" => first, "errors" => []}}} =
             graphql(create_mutation(:event, event.id, "GLOBAL_CODE", 1), token)

    assert %{"data" => %{"createInviteBatch" => %{"result" => nil, "errors" => errors}}} =
             graphql(create_mutation(:course, course.id, "GLOBAL_CODE", 1), token)

    assert Enum.map_join(errors, " ", & &1["message"]) =~ "already been taken"

    # #242：断言按本测试唯一 invite_code 隔离，避免共享表残留污染全局 count
    assert length(
             InviteBatch
             |> Ash.Query.filter(invite_code == "GLOBAL_CODE")
             |> Ash.read!(authorize?: false)
           ) == 1

    assert first["inviteCode"] == "GLOBAL_CODE"
  end

  test "disable 成功，list 按 eventId 与 courseId filter 返回正确批次" do
    %{owner: owner, workspace: workspace} = managed_workspace()
    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :invite_only})
    other_event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :invite_only})
    course = EventFixtures.create_course(workspace, owner, %{enrollment_policy: :invite_only})
    token = sign_in_token(owner)

    event_batch =
      create_batch!(token, :event, event.id, "EVENT_CODE", 4)

    _other_batch =
      create_batch!(token, :event, other_event.id, "OTHER_EVENT", 2)

    course_batch =
      create_batch!(token, :course, course.id, "COURSE_CODE", 5)

    event_list = graphql(list_query(:event, event.id, workspace.id), token)

    assert %{"data" => %{"inviteBatches" => %{"results" => [listed_event], "endKeyset" => _}}} =
             event_list

    assert listed_event["id"] == event_batch["id"]
    assert listed_event["eventId"] == event.id
    assert listed_event["courseId"] == nil
    assert listed_event["insertedAt"] == event_batch["insertedAt"]

    course_list = graphql(list_query(:course, course.id, workspace.id), token)

    assert %{"data" => %{"inviteBatches" => %{"results" => [listed_course]}}} = course_list
    assert listed_course["id"] == course_batch["id"]
    assert listed_course["courseId"] == course.id

    disable_response = graphql(disable_mutation(event_batch["id"]), token)

    assert %{"data" => %{"disableInviteBatch" => %{"result" => disabled, "errors" => []}}} =
             disable_response

    assert disabled["id"] == event_batch["id"]
    assert disabled["status"] == "disabled"
  end

  test "普通成员不能经 GraphQL 创建批次码" do
    %{owner: owner, member: member, workspace: workspace} = Fixtures.workspace_with_member()
    event = EventFixtures.create_event(workspace, owner, %{enrollment_policy: :invite_only})

    response =
      graphql(create_mutation(:event, event.id, "MEMBER_CODE", 1), sign_in_token(member))

    assert %{"data" => %{"createInviteBatch" => %{"result" => nil, "errors" => errors}}} =
             response

    assert errors != []
  end

  defp managed_workspace do
    %{owner: owner, member: member, workspace: workspace} = Fixtures.workspace_with_member()
    admin = Fixtures.register_user("gql-invite-admin")
    Fixtures.add_member(workspace, admin, [:admin])
    %{owner: owner, admin: admin, member: member, workspace: workspace}
  end

  defp create_batch!(token, kind, id, code, quota) do
    response = graphql(create_mutation(kind, id, code, quota), token)

    assert %{"data" => %{"createInviteBatch" => %{"result" => result, "errors" => []}}} =
             response

    result
  end

  defp create_mutation(kind, id, code, quota, remark \\ nil)

  defp create_mutation(:event, id, code, quota, remark) do
    remark_input = if remark, do: ~s(, remark: "#{remark}"), else: ""

    """
    mutation {
      createInviteBatch(input: {eventId: "#{id}", inviteCode: "#{code}", quota: #{quota}#{remark_input}}) {
        result { id workspaceId eventId courseId inviteCode quota remainingQuota status insertedAt remark }
        errors { message code }
      }
    }
    """
  end

  defp create_mutation(:course, id, code, quota, remark) do
    remark_input = if remark, do: ~s(, remark: "#{remark}"), else: ""

    """
    mutation {
      createInviteBatch(input: {courseId: "#{id}", inviteCode: "#{code}", quota: #{quota}#{remark_input}}) {
        result { id workspaceId eventId courseId inviteCode quota remainingQuota status insertedAt remark }
        errors { message code }
      }
    }
    """
  end

  defp list_query(:event, id, workspace_id) do
    """
    query {
      inviteBatches(
        filter: {eventId: {eq: "#{id}"}, workspaceId: {eq: "#{workspace_id}"}}
        first: 50
      ) {
        results { id workspaceId eventId courseId inviteCode quota remainingQuota status insertedAt remark }
        endKeyset
      }
    }
    """
  end

  defp list_query(:course, id, workspace_id) do
    """
    query {
      inviteBatches(
        filter: {courseId: {eq: "#{id}"}, workspaceId: {eq: "#{workspace_id}"}}
        first: 50
      ) {
        results { id workspaceId eventId courseId inviteCode quota remainingQuota status insertedAt remark }
        endKeyset
      }
    }
    """
  end

  defp disable_mutation(id) do
    """
    mutation {
      disableInviteBatch(id: "#{id}") {
        result { id workspaceId eventId courseId inviteCode quota remainingQuota status insertedAt remark }
        errors { message code }
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
