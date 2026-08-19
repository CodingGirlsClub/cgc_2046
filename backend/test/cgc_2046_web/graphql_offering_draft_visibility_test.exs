defmodule Cgc2046Web.GraphqlOfferingDraftVisibilityTest do
  @moduledoc """
  016 draft 读收紧的 GraphQL HTTP 层：get/slug/count 的 not_found 同形、
  speaker card 例外、list_for_event 统一错误、sponsorship not_open、
  以及无 workspaceId 的全局 list sentinel。
  """

  use Cgc2046Web.ConnCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event, SpeakerInvitation}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  @missing_id "00000000-0000-4000-8000-000000000099"

  describe "member draft get / slug / count" do
    test "member 对 draft event/course get 与随机不存在 id 错误同形" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      event_draft = create_draft(Event, workspace, owner, "GQL Event Draft")
      course_draft = create_draft(Course, workspace, owner, "GQL Course Draft")
      token = sign_in_token(member)

      event_draft_res = graphql(get_event_query(event_draft.id), token)
      event_missing_res = graphql(get_event_query(@missing_id), token)
      assert_same_not_found(event_draft_res, event_missing_res, "getEvent")

      course_draft_res = graphql(get_course_query(course_draft.id), token)
      course_missing_res = graphql(get_course_query(@missing_id), token)
      assert_same_not_found(course_draft_res, course_missing_res, "getCourse")
    end

    test "member getEventBySlug draft → 与不存在 slug 同形 null" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      draft = create_draft(Event, workspace, owner, "GQL Slug Draft")
      token = sign_in_token(member)

      draft_res = graphql(get_event_by_slug_query(draft.slug), token)
      missing_res = graphql(get_event_by_slug_query("no-such-offering-slug"), token)
      assert_same_not_found(draft_res, missing_res, "getEventBySlug")
    end

    test "member getCourseBySlug draft → 与不存在 slug 同形 null" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      draft = create_draft(Course, workspace, owner, "GQL Course Slug Draft")
      token = sign_in_token(member)

      draft_res = graphql(get_course_by_slug_query(draft.slug), token)
      missing_res = graphql(get_course_by_slug_query("no-such-course-slug"), token)
      assert_same_not_found(draft_res, missing_res, "getCourseBySlug")
    end

    test "listEvents/listCourses count 对 member 不计 draft" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      _draft_event = create_draft(Event, workspace, owner, "Hidden Event Draft")
      _draft_course = create_draft(Course, workspace, owner, "Hidden Course Draft")
      open_event = EventFixtures.create_event(workspace, owner, %{title: "Visible Event"})
      open_course = EventFixtures.create_course(workspace, owner, %{title: "Visible Course"})
      token = sign_in_token(member)

      events =
        graphql(
          """
          query {
            listEvents(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
              count
              results { id title }
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "listEvents" => %{"count" => 1, "results" => [%{"id" => event_id}]}
               }
             } = events

      assert event_id == open_event.id

      courses =
        graphql(
          """
          query {
            listCourses(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
              count
              results { id title }
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "listCourses" => %{"count" => 1, "results" => [%{"id" => course_id}]}
               }
             } = courses

      assert course_id == open_course.id
    end
  end

  describe "global list sentinel" do
    test "member 无 filter 全局 list 不返回跨租户/非成员 draft，且 count 不泄露" do
      a = Fixtures.workspace_with_member()
      b = Fixtures.workspace_with_member()

      hidden_event_draft = create_draft(Event, a.workspace, a.owner, "A Hidden Event Draft")
      foreign_event_draft = create_draft(Event, b.workspace, b.owner, "B Hidden Event Draft")

      visible_event_open =
        EventFixtures.create_event(a.workspace, a.owner, %{title: "A Open Event"})

      public_event_open =
        EventFixtures.create_event(b.workspace, b.owner, %{
          title: "B Public Open Event",
          visibility: :public
        })

      hidden_course_draft = create_draft(Course, a.workspace, a.owner, "A Hidden Course Draft")
      foreign_course_draft = create_draft(Course, b.workspace, b.owner, "B Hidden Course Draft")

      visible_course_open =
        EventFixtures.create_course(a.workspace, a.owner, %{title: "A Open Course"})

      public_course_open =
        EventFixtures.create_course(b.workspace, b.owner, %{
          title: "B Public Open Course",
          visibility: :public
        })

      token = sign_in_token(a.member)

      events =
        graphql(
          """
          query {
            listEvents {
              count
              results { id title status }
            }
          }
          """,
          token
        )

      event_results = events["data"]["listEvents"]["results"]
      event_ids = Enum.map(event_results, & &1["id"])

      assert visible_event_open.id in event_ids
      assert public_event_open.id in event_ids
      refute hidden_event_draft.id in event_ids
      refute foreign_event_draft.id in event_ids
      assert events["data"]["listEvents"]["count"] == length(event_results)

      courses =
        graphql(
          """
          query {
            listCourses {
              count
              results { id title status }
            }
          }
          """,
          token
        )

      course_results = courses["data"]["listCourses"]["results"]
      course_ids = Enum.map(course_results, & &1["id"])

      assert visible_course_open.id in course_ids
      assert public_course_open.id in course_ids
      refute hidden_course_draft.id in course_ids
      refute foreign_course_draft.id in course_ids
      assert courses["data"]["listCourses"]["count"] == length(course_results)
    end
  end

  describe "speakerInvitationCard 例外与 list 错误统一" do
    test "有效 token 对 draft event 仍返回卡片" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
      draft = create_draft(Event, workspace, owner, "Invite Draft")

      {:ok, _invitation, token} =
        SpeakerInvitation.issue(
          %{event_id: draft.id, speaker_name: "嘉宾甲", speaker_email: "draft-speaker@example.com"},
          owner,
          workspace.id
        )

      res =
        anon("""
        query {
          speakerInvitationCard(token: "#{token}") {
            status
            event { title status }
          }
        }
        """)

      assert %{
               "data" => %{
                 "speakerInvitationCard" => %{
                   "status" => "invited",
                   "event" => %{"title" => "Invite Draft", "status" => "draft"}
                 }
               }
             } = res
    end

    test "无效 token 仍不可达" do
      res =
        anon("""
        query {
          speakerInvitationCard(token: "no-such-token") {
            status
          }
        }
        """)

      assert %{"data" => %{"speakerInvitationCard" => nil}, "errors" => [%{"message" => message}]} =
               res

      assert message =~ "invalid, expired or already used"
    end

    test "member list speakerInvitations：存在 draft 与不存在 id 同为 not_found" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      draft = create_draft(Event, workspace, owner, "List Invite Draft")
      token = sign_in_token(member)

      draft_res = graphql(speaker_invitations_query(draft.id), token)
      missing_res = graphql(speaker_invitations_query(@missing_id), token)

      assert %{"data" => nil, "errors" => draft_errors} = draft_res
      assert %{"data" => nil, "errors" => missing_errors} = missing_res
      assert error_shape(draft_errors) == error_shape(missing_errors)
      assert_not_found_errors(draft_errors)
    end
  end

  describe "createSponsorship draft public event" do
    test "draft public event → sponsorship_not_open" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

      draft =
        create_draft(Event, workspace, owner, "Sponsor Draft", %{
          visibility: :public,
          sponsorship_enabled: true
        })

      sponsor = Fixtures.register_user("gql-draft-sponsor")
      token = sign_in_token(sponsor)

      res =
        graphql(
          """
          mutation {
            createSponsorship(input: {
              level: "event"
              eventId: "#{draft.id}"
              sponsorUserId: "#{sponsor.id}"
              companyName: "Draft Oracle"
              contactEmail: "#{sponsor.email}"
            }) {
              result { id }
              errors { message }
            }
          }
          """,
          token
        )

      assert %{
               "data" => %{
                 "createSponsorship" => %{"result" => nil, "errors" => errors}
               }
             } = res

      assert Enum.map_join(errors, " ", & &1["message"]) =~ "does not accept sponsorships"
    end
  end

  defp create_draft(resource, workspace, actor, title, extra \\ %{}) do
    attrs = Map.merge(%{title: title, enrollment_policy: :open}, extra)

    resource
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: actor)
  end

  defp get_event_query(id) do
    """
    query {
      getEvent(id: "#{id}") { id title }
    }
    """
  end

  defp get_course_query(id) do
    """
    query {
      getCourse(id: "#{id}") { id title }
    }
    """
  end

  defp get_event_by_slug_query(slug) do
    """
    query {
      getEventBySlug(slug: "#{slug}") { id slug }
    }
    """
  end

  defp get_course_by_slug_query(slug) do
    """
    query {
      getCourseBySlug(slug: "#{slug}") { id slug }
    }
    """
  end

  defp speaker_invitations_query(event_id) do
    """
    query {
      speakerInvitations(eventId: "#{event_id}") { id }
    }
    """
  end

  defp assert_same_not_found(left, right, field) do
    assert %{"data" => %{^field => nil}} = left
    assert %{"data" => %{^field => nil}} = right
    assert Map.get(left, "errors") == Map.get(right, "errors")

    case Map.get(left, "errors") do
      nil -> :ok
      errors -> assert_not_found_errors(errors)
    end
  end

  defp assert_not_found_errors(errors) do
    assert Enum.any?(errors, fn error ->
             error["code"] == "not_found" or error["message"] == "could not be found"
           end)
  end

  defp error_shape(errors) do
    errors
    |> Enum.map(&{&1["code"], &1["message"], &1["fields"]})
    |> Enum.sort()
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
end
