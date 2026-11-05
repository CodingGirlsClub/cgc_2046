defmodule Cgc2046Web.McpAuthorizationTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Flashback.{EventArchive, Outreach, Person, Wish, WishComment, Wishes}
  alias Cgc2046.Mcp.{PendingOperation, Token, ToolCallLog}
  alias Cgc2046.Recruitment.RecruitmentCohort
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  require Ash.Query

  defp post_mcp(token, body, session \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    post(conn, "/mcp", Jason.encode!(body))
  end

  defp client(user) do
    {:ok, _token, plain} = Token.issue("authorization regression", user, :terminal)

    conn =
      post_mcp(plain, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "authorization-test", version: "0.0.0"}
        }
      })

    assert conn.status == 200
    [session] = get_resp_header(conn, "mcp-session-id")
    %{token: plain, session: session}
  end

  defp call(client, name, params) do
    conn =
      post_mcp(
        client.token,
        %{
          jsonrpc: "2.0",
          id: System.unique_integer([:positive]),
          method: "tools/call",
          params: %{name: name, arguments: params}
        },
        client.session
      )

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp payload(%{"result" => %{"content" => [%{"text" => text}]}}),
    do: Jason.decode!(text)

  defp confirm(client, pending),
    do: call(client, "confirm_operation", %{"pending_id" => pending["pending_id"]})

  defp assert_forbidden(response) do
    assert %{"error" => %{"message" => message}} = response
    assert String.starts_with?(message, "forbidden:")
  end

  defp logs(user, tool) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user.id and tool == ^tool)
    |> Ash.read!(authorize?: false)
  end

  describe "platform admin revocation during confirmation (#1087)" do
    for tool <-
          ~w(admin_send_flashback_outreach admin_resend_flashback_outreach admin_soft_delete_wish admin_soft_delete_wish_comment) do
      test "#{tool} rechecks admin privileges before effects" do
        tool = unquote(tool)
        admin = Fixtures.platform_admin("pending-admin")
        other_admin = Fixtures.platform_admin("remaining-admin")
        client = client(admin)
        %{params: params} = target = flashback_target(tool)

        pending = client |> call(tool, params) |> payload()
        assert pending["status"] == "needs_confirmation"
        before = flashback_effects(target)

        demoted =
          admin
          |> Ash.Changeset.for_update(:demote_platform_admin, %{}, actor: other_admin)
          |> Ash.update!(actor: other_admin)

        refute demoted.is_platform_admin
        assert_forbidden(confirm(client, pending))
        assert flashback_effects(target) == before

        assert Ash.get!(PendingOperation, pending["pending_id"], authorize?: false).status ==
                 :pending

        assert [%{result_status: :forbidden}] = logs(admin, "confirm_operation")

        demoted
        |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true},
          actor: other_admin
        )
        |> Ash.update!(actor: other_admin)

        assert %{"status" => "confirmed"} = client |> confirm(pending) |> payload()
        refute flashback_effects(target) == before
      end
    end
  end

  defp flashback_target(tool) do
    archive =
      EventArchive
      |> Ash.Changeset.for_create(:create, %{
        key: "mcp-auth-#{System.unique_integer([:positive])}",
        name: "Authorization archive",
        city: "Beijing",
        occurred_on: ~D[2014-01-11]
      })
      |> Ash.create!(authorize?: false)

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: "Test Person",
        surname: "Test",
        city: "Beijing",
        participation: :attended,
        email: "authorization@example.com"
      })
      |> Ash.create!(authorize?: false)

    wish = Cgc2046.FlashbackFixtures.listed_wish!(person.id, "Authorization wish")
    {:ok, [comment]} = Wishes.add_comment(person.id, wish.id, "Authorization comment")

    params =
      case tool do
        "admin_send_flashback_outreach" ->
          %{"archive_key" => archive.key, "template" => "reconnect", "channel" => "email"}

        "admin_resend_flashback_outreach" ->
          %{"person_id" => person.id, "template" => "reconnect", "channel" => "email"}

        "admin_soft_delete_wish" ->
          %{"wish_id" => wish.id, "reason" => "Moderation test"}

        "admin_soft_delete_wish_comment" ->
          %{"comment_id" => comment.id, "reason" => "Moderation test"}
      end

    %{params: params, person: person, wish: wish, comment: comment}
  end

  defp flashback_effects(target) do
    outreach =
      Outreach
      |> Ash.Query.filter(person_id == ^target.person.id)
      |> Ash.read!(authorize?: false, page: false)

    %{
      outreach: length(outreach),
      wish_deleted_at: Ash.get!(Wish, target.wish.id, authorize?: false).deleted_at,
      comment_deleted_at: Ash.get!(WishComment, target.comment.id, authorize?: false).deleted_at
    }
  end

  describe "default reviewer authorization (#1084)" do
    for {tool, review_required} <- [
          {"approve_prep", true},
          {"override_prep_gate", true},
          {"override_prep_gate", false},
          {"request_changes_prep", true}
        ] do
      test "#{tool} rejects unassigned users (review_required=#{review_required})" do
        tool = unquote(tool)
        review_required = unquote(review_required)
        %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
        learner = Fixtures.register_user("review-learner")
        Fixtures.add_member(workspace, learner, [:learner])
        unassigned_tutor = Fixtures.register_user("unassigned-tutor")
        Fixtures.add_member(workspace, unassigned_tutor, [:tutor])
        {course, run} = prep_fixture(workspace, owner, tool, nil, review_required)
        params = %{"workspace_id" => workspace.id, "course_id" => course.id, "reason" => "Review"}

        for user <- [member, learner, unassigned_tutor] do
          assert_forbidden(call(client(user), tool, params))
          assert Ash.get!(WorkflowRun, run.id, authorize?: false).facts == run.facts
          assert Ash.get!(Course, course.id, authorize?: false).status == :draft

          assert [] =
                   PendingOperation
                   |> Ash.Query.filter(user_id == ^user.id)
                   |> Ash.read!(authorize?: false)

          assert [%{result_status: :forbidden}] = logs(user, tool)
        end
      end
    end

    for tool <- ~w(approve_prep override_prep_gate) do
      test "#{tool} rejects confirmation after the assigned tutor changes" do
        tool = unquote(tool)
        %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()
        tutor = Fixtures.register_user("assigned-tutor")
        Fixtures.add_member(workspace, tutor, [:tutor])
        {course, run} = prep_fixture(workspace, owner, tool)
        {:ok, run} = Prep.assign_tutor(run, tutor.id, owner)
        client = client(tutor)
        params = %{"workspace_id" => workspace.id, "course_id" => course.id, "reason" => "Review"}
        pending = client |> call(tool, params) |> payload()
        assert pending["status"] == "needs_confirmation"

        {:ok, reassigned} = Prep.assign_tutor(run, owner.id, owner)
        assert_forbidden(confirm(client, pending))
        assert Ash.get!(WorkflowRun, run.id, authorize?: false).facts == reassigned.facts

        assert Ash.get!(PendingOperation, pending["pending_id"], authorize?: false).status ==
                 :pending

        assert Ash.get!(Course, course.id, authorize?: false).status == :draft
      end
    end

    test "an explicit reviewer can review without a staff role" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      {course, run} = prep_fixture(workspace, owner, "request_changes_prep", member.id)
      client = client(member)

      result =
        client
        |> call("request_changes_prep", %{
          "workspace_id" => workspace.id,
          "course_id" => course.id,
          "reason" => "Please revise the lesson"
        })
        |> payload()

      assert result["prep_state"] == "authoring"
      updated = Ash.get!(WorkflowRun, run.id, authorize?: false)
      assert [%{"requested_by" => reviewer_id}] = updated.facts["change_requests"]
      assert reviewer_id == member.id
    end
  end

  defp prep_fixture(workspace, owner, tool, reviewer_id \\ nil, review_required \\ true) do
    WorkflowDefinition
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Authorization preparation",
        type: :course_preparation,
        input_schema: %{},
        node_def: %{"steps" => []}
      },
      tenant: workspace.id,
      actor: owner
    )
    |> Ash.create!(tenant: workspace.id, actor: owner)
    |> Ash.Changeset.for_update(:publish, %{}, tenant: workspace.id, actor: owner)
    |> Ash.update!(tenant: workspace.id, actor: owner)

    course = draft(Course, workspace, owner)
    {:ok, run} = Prep.ensure_active_run(course, actor: owner)

    facts =
      Map.merge(run.facts || %{}, %{
        "prep_state" => if(tool == "override_prep_gate", do: "authoring", else: "review"),
        "below_threshold_pending" => true,
        "prep_policy_override" => %{
          "reviewer_user_id" => reviewer_id,
          "review_required" => review_required
        }
      })

    run =
      run
      |> Ash.Changeset.for_update(:update_prep_facts, %{facts: facts}, tenant: workspace.id)
      |> Ash.update!(tenant: workspace.id, actor: owner)

    {course, run}
  end

  describe "workspace lists follow domain visibility (#1084)" do
    for {resource, tool, list_key, id_key} <- [
          {Course, "list_workspace_courses", "courses", "course_id"},
          {Event, "list_workspace_events", "events", "event_id"},
          {RecruitmentCohort, "list_recruitment_cohorts", "cohorts", "cohort_id"}
        ] do
      test "#{tool} returns the actor's domain-visible set" do
        resource = unquote(resource)
        tool = unquote(tool)
        list_key = unquote(list_key)
        id_key = unquote(id_key)
        %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
        learner = Fixtures.register_user("list-learner")
        Fixtures.add_member(workspace, learner, [:learner])
        tutor = Fixtures.register_user("list-tutor")
        Fixtures.add_member(workspace, tutor, [:tutor])
        admin = Fixtures.register_user("list-admin")
        Fixtures.add_member(workspace, admin, [:admin])
        draft = draft(resource, workspace, owner)
        closed = close(open(resource, workspace, owner), workspace, owner)
        open = open(resource, workspace, owner)
        cancelled = cancelled(resource, workspace, owner)

        for actor <- [member, learner, tutor, admin, owner] do
          expected =
            expected_ids(
              resource,
              actor,
              [admin.id, owner.id],
              tutor,
              draft,
              open,
              closed,
              cancelled
            )

          domain_ids =
            resource
            |> Ash.read!(actor: actor, tenant: workspace.id, page: false)
            |> Enum.map(& &1.id)
            |> Enum.sort()

          assert domain_ids == expected
          client = client(actor)
          result = client |> call(tool, %{"workspace_id" => workspace.id}) |> payload()
          assert result["count"] == length(expected)
          assert Enum.sort(Enum.map(result[list_key], & &1[id_key])) == expected

          draft_result =
            client
            |> call(tool, %{"workspace_id" => workspace.id, "status" => "draft"})
            |> payload()

          expected_drafts = if draft.id in expected, do: [draft.id], else: []
          assert Enum.map(draft_result[list_key], & &1[id_key]) == expected_drafts
        end
      end
    end

    test "invitation summaries cannot reveal draft course titles to members" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      course = draft(Course, workspace, owner)

      params = %{
        "workspace_id" => workspace.id,
        "prep_course_ids" => [course.id],
        "preauthorized_role_names" => ["tutor"]
      }

      assert %{"error" => %{"message" => message}} =
               call(client(member), "create_invitation", params)

      assert message =~ "course not found"

      assert [] =
               PendingOperation
               |> Ash.Query.filter(user_id == ^member.id)
               |> Ash.read!(authorize?: false)

      pending = client(owner) |> call("create_invitation", params) |> payload()
      assert pending["status"] == "needs_confirmation"
      assert pending["summary"] =~ course.title
    end

    test "a member cannot read a draft through preparation status" do
      %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
      {course, _run} = prep_fixture(workspace, owner, "approve_prep")
      params = %{"workspace_id" => workspace.id, "course_id" => course.id}

      assert %{"error" => %{"message" => message}} =
               call(client(member), "get_prep_status", params)

      assert message =~ "course not found"

      assert %{"course_id" => course_id} =
               client(owner) |> call("get_prep_status", params) |> payload()

      assert course_id == course.id
    end
  end

  defp expected_ids(resource, actor, managers, tutor, draft, open, closed, cancelled) do
    cond do
      actor.id in managers ->
        Enum.reject([draft, open, closed, cancelled], &is_nil/1) |> Enum.map(& &1.id)

      resource == RecruitmentCohort ->
        [open.id]

      resource == Course and actor.id == tutor.id ->
        [draft.id, open.id, closed.id]

      true ->
        [open.id, closed.id]
    end
    |> Enum.sort()
  end

  defp draft(RecruitmentCohort, workspace, owner) do
    RecruitmentCohort
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Authorization cohort", apply_deadline_at: EventsFixtures.days_from_now(7)},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: owner)
  end

  defp draft(resource, workspace, owner) do
    resource
    |> Ash.Changeset.for_create(
      :create,
      %{title: "Authorization offering", registration_deadline: EventsFixtures.days_from_now(7)},
      tenant: workspace.id
    )
    |> Ash.create!(tenant: workspace.id, actor: owner)
  end

  defp open(Course, workspace, owner), do: EventsFixtures.create_course(workspace, owner)
  defp open(Event, workspace, owner), do: EventsFixtures.create_event(workspace, owner)

  defp open(RecruitmentCohort, workspace, owner) do
    draft(RecruitmentCohort, workspace, owner)
    |> Ash.Changeset.for_update(:open, %{}, tenant: workspace.id)
    |> Ash.update!(tenant: workspace.id, actor: owner)
  end

  defp cancelled(RecruitmentCohort, _workspace, _owner), do: nil

  defp cancelled(resource, workspace, owner) do
    open(resource, workspace, owner)
    |> Ash.Changeset.for_update(:cancel, %{}, tenant: workspace.id)
    |> Ash.update!(tenant: workspace.id, actor: owner)
  end

  defp close(record, workspace, owner) do
    record
    |> Ash.Changeset.for_update(:close, %{}, tenant: workspace.id)
    |> Ash.update!(tenant: workspace.id, actor: owner)
  end
end
