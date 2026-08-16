defmodule Cgc2046Web.GraphqlMyLearningRunsTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Workflows.{Step, WorkflowDefinition, WorkflowRun}

  test "confirmed 学员可读自己的 run，issue 级进度口径(U7)" do
    owner = Fixtures.platform_admin("my-learning-owner")
    workspace = Fixtures.create_workspace(owner)
    learner = Fixtures.register_user("my-learning-learner")
    event = EventFixtures.create_event(workspace, owner, %{title: "学习活动"})

    enrollment =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        %{
          event_id: event.id,
          user_id: learner.id,
          submission_payload: %{"targetTitle" => "快照标题"}
        },
        tenant: workspace.id,
        actor: learner
      )
      |> Ash.create!(tenant: workspace.id, actor: learner)

    definition = create_learning_definition(workspace, owner, "outline", "review")
    waiting_run = create_running_run(workspace, definition, enrollment)

    waiting_run =
      waiting_run
      |> Ash.Changeset.for_update(:update_facts_for_mcp, %{facts: %{}}, authorize?: false)
      |> Ash.update!(tenant: workspace.id, authorize?: false)
      |> then(&Ash.Changeset.for_update(&1, :wait, %{}, authorize?: false))
      |> Ash.update!(tenant: workspace.id, authorize?: false)

    succeeded_run = create_running_run(workspace, definition, enrollment)

    succeeded_run =
      succeeded_run
      |> Ash.Changeset.for_update(
        :complete,
        %{facts: %{"outline" => %{"ok" => true}, "review" => %{"ok" => true}}},
        authorize?: false
      )
      |> Ash.update!(tenant: workspace.id, authorize?: false)

    response = graphql(my_learning_runs_query(), sign_in_token(learner))
    assert %{"data" => %{"myLearningRuns" => rows}} = response

    assert Enum.map(rows, & &1["runId"]) |> MapSet.new() ==
             MapSet.new([waiting_run.id, succeeded_run.id])

    waiting = Enum.find(rows, &(&1["runId"] == waiting_run.id))
    assert waiting["enrollmentId"] == enrollment.id
    assert waiting["targetTitle"] == "快照标题"
    assert waiting["status"] == "waiting"
    # U7(KD8):issue 级口径。事件型 enrollment(无 course content)→ 0/0
    assert waiting["doneIssues"] == 0
    assert waiting["totalIssues"] == 0
    assert waiting["currentIssueTitle"] == nil

    succeeded = Enum.find(rows, &(&1["runId"] == succeeded_run.id))
    assert succeeded["status"] == "succeeded"
    assert succeeded["doneIssues"] == 0
    assert succeeded["totalIssues"] == 0
    assert succeeded["currentIssueTitle"] == nil
  end

  test "无 confirmed enrollment 的用户返回空列表，未登录被拒" do
    learner = Fixtures.register_user("my-learning-empty")

    assert %{"data" => %{"myLearningRuns" => []}} =
             graphql(my_learning_runs_query(), sign_in_token(learner))

    response = graphql(my_learning_runs_query(), nil)
    assert %{"data" => nil, "errors" => [%{"code" => "unauthorized"}]} = response
  end

  test "租户错配或他人的 enrollment anchor 均 fail-closed" do
    owner = Fixtures.platform_admin("my-learning-isolation-owner")
    workspace_a = Fixtures.create_workspace(owner)
    workspace_b = Fixtures.create_workspace(owner)
    learner_a = Fixtures.register_user("my-learning-isolation-a")
    learner_b = Fixtures.register_user("my-learning-isolation-b")
    event_a = EventFixtures.create_event(workspace_a, owner, %{title: "A 活动"})
    event_b = EventFixtures.create_event(workspace_b, owner, %{title: "B 活动"})

    enrollment_a =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        %{event_id: event_a.id, user_id: learner_a.id},
        tenant: workspace_a.id,
        actor: learner_a
      )
      |> Ash.create!(tenant: workspace_a.id, actor: learner_a)

    enrollment_b =
      Enrollment
      |> Ash.Changeset.for_create(
        :create_enrollment,
        %{event_id: event_b.id, user_id: learner_b.id},
        tenant: workspace_b.id,
        actor: learner_b
      )
      |> Ash.create!(tenant: workspace_b.id, actor: learner_b)

    definition_b = create_learning_definition(workspace_b, owner, "b-step", "b-last")

    _mismatched_run =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: definition_b.id,
          definition_version: definition_b.version,
          input_snapshot: %{"enrollment_id" => enrollment_a.id}
        },
        tenant: workspace_b.id,
        authorize?: false
      )
      |> Ash.create!(tenant: workspace_b.id, authorize?: false)

    _other_user_run = create_running_run(workspace_b, definition_b, enrollment_b)

    response = graphql(my_learning_runs_query(), sign_in_token(learner_a))
    assert %{"data" => %{"myLearningRuns" => []}} = response
  end

  defp create_learning_definition(workspace, actor, first_key, last_key) do
    node_def = %{
      "steps" => [
        %{"id" => first_key, "type" => "manual"},
        %{"id" => last_key, "type" => "manual"}
      ]
    }

    definition =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{name: "学习 workflow", type: :learning, input_schema: %{}, node_def: node_def},
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create!(tenant: workspace.id, actor: actor)

    definition =
      definition
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update!(tenant: workspace.id, actor: actor)

    for key <- [first_key, last_key] do
      Step
      |> Ash.Changeset.for_create(
        :create,
        %{definition_id: definition.id, step_key: key, title: "#{key} 标题", type: :manual},
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create!(tenant: workspace.id, actor: actor)
    end

    definition
  end

  defp create_running_run(workspace, definition, enrollment) do
    WorkflowRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        definition_id: definition.id,
        definition_version: definition.version,
        input_snapshot: %{"enrollment_id" => enrollment.id}
      },
      tenant: workspace.id,
      authorize?: false
    )
    |> Ash.create!(tenant: workspace.id, authorize?: false)
    |> then(&Ash.Changeset.for_update(&1, :start, %{}, authorize?: false))
    |> Ash.update!(tenant: workspace.id, authorize?: false)
  end

  defp my_learning_runs_query do
    """
    query {
      myLearningRuns {
        runId
        enrollmentId
        targetTitle
        status
        doneIssues
        totalIssues
        currentIssueTitle
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
