defmodule Cgc2046Web.McpPrepStatusAuthorizationTest do
  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Courses.Course
  alias Cgc2046.Curriculum.Prep
  alias Cgc2046.EventsFixtures
  alias Cgc2046.Mcp.Token
  alias Cgc2046.Workflows.WorkflowDefinition

  setup do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

    WorkflowDefinition
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Reviewer preparation",
        type: :course_preparation,
        input_schema: %{},
        node_def: %{"steps" => []}
      },
      actor: owner,
      tenant: workspace.id
    )
    |> Ash.create!(actor: owner, tenant: workspace.id)
    |> Ash.Changeset.for_update(:publish, %{}, actor: owner, tenant: workspace.id)
    |> Ash.update!(actor: owner, tenant: workspace.id)

    course = draft(workspace, owner)
    {:ok, run} = Prep.ensure_active_run(course, actor: owner)
    report = %{"score" => 95, "summary" => "Ready for review", "outcome" => "review"}

    run =
      update_facts(
        run,
        %{
          "prep_state" => "review",
          "assignee_user_id" => owner.id,
          "prep_policy_override" => %{"reviewer_user_id" => member.id, "quality_threshold" => 90},
          "latest_quality_report" => report
        },
        owner
      )

    %{
      owner: owner,
      workspace: workspace,
      reviewer: member,
      course: course,
      run: run,
      report: report,
      client: client(member),
      params: %{"workspace_id" => workspace.id, "course_id" => course.id}
    }
  end

  test "a designated reviewer can inspect the preparation task without a staff role", ctx do
    tasks =
      ctx.client |> call("list_my_tasks", %{"workspace_id" => ctx.workspace.id}) |> payload()

    assert Enum.any?(
             tasks["tasks"],
             &(&1["course_id"] == ctx.course.id and &1["kind"] == "course_prep_review")
           )

    assert Prep.reviewer?(ctx.run, ctx.reviewer)

    status = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    assert status["course_id"] == ctx.course.id
    assert status["run_id"] == ctx.run.id
    assert status["prep_state"] == "review"
    assert status["policy"]["reviewer_user_id"] == ctx.reviewer.id
    assert status["policy"]["quality_threshold"] == 90
    assert status["latest_quality_report"] == ctx.report
    assert status["gate_violations"] == Prep.gate(ctx.course).violations
    assert status["gate_violations"] != []
    assert status["tutor"]["user_id"] == ctx.owner.id
    assert status["version"] == ctx.run.version

    open = EventsFixtures.create_course(ctx.workspace, ctx.owner)

    listed =
      ctx.client
      |> call("list_workspace_courses", %{"workspace_id" => ctx.workspace.id})
      |> payload()

    assert Enum.map(listed["courses"], & &1["course_id"]) == [open.id]
    assert {:error, _} = Course.fetch_scoped(ctx.workspace.id, ctx.course.id, actor: ctx.reviewer)
  end

  test "the current assignee can inspect preparation after losing the tutor role", ctx do
    run =
      update_facts(
        ctx.run,
        %{
          "assignee_user_id" => ctx.reviewer.id,
          "prep_policy_override" => %{"reviewer_user_id" => nil}
        },
        ctx.owner
      )

    assert Prep.reviewer?(run, ctx.reviewer)
    status = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    assert status["assignee_user_id"] == ctx.reviewer.id
    assert status["latest_quality_report"] == ctx.report
  end

  test "changing the designated reviewer revokes access in the same session", ctx do
    run = update_facts(ctx.run, %{"prep_state" => "authoring"}, ctx.owner)
    assert %{"run_id" => run_id} = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    assert run_id == run.id
    assert {:ok, _} = Prep.update_policy(run, %{"reviewer_user_id" => ctx.owner.id}, ctx.owner)
    assert_not_found(call(ctx.client, "get_prep_status", ctx.params), ctx.course.id)
  end

  test "removing the reviewer from the workspace revokes access in the same session", ctx do
    assert %{"run_id" => _} = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    Fixtures.remove_membership(ctx.workspace, ctx.reviewer)
    assert %{"error" => %{"message" => message}} = call(ctx.client, "get_prep_status", ctx.params)
    assert String.starts_with?(message, "forbidden:")
  end

  test "review authorization is limited to the current course and workspace", ctx do
    assert %{"run_id" => _} = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    other_course = draft(ctx.workspace, ctx.owner)
    {:ok, _} = Prep.ensure_active_run(other_course, actor: ctx.owner)
    params = Map.put(ctx.params, "course_id", other_course.id)
    assert_not_found(call(ctx.client, "get_prep_status", params), other_course.id)

    other = Fixtures.workspace_with_member()
    Fixtures.add_member(other.workspace, ctx.reviewer)
    foreign_course = draft(other.workspace, other.owner)
    params = Map.put(ctx.params, "course_id", foreign_course.id)
    assert_not_found(call(ctx.client, "get_prep_status", params), foreign_course.id)

    assert_not_found(
      call(ctx.client, "get_prep_status", Map.put(params, "workspace_id", other.workspace.id)),
      foreign_course.id
    )
  end

  test "a draft without an active preparation run stays hidden without creating a run", ctx do
    assert %{"run_id" => _} = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    hidden = draft(ctx.workspace, ctx.owner)
    assert is_nil(Prep.fetch_run(hidden.id, ctx.workspace.id))

    assert_not_found(
      call(ctx.client, "get_prep_status", Map.put(ctx.params, "course_id", hidden.id)),
      hidden.id
    )

    assert is_nil(Prep.fetch_run(hidden.id, ctx.workspace.id))
    assert is_nil(Ash.get!(Course, hidden.id, authorize?: false).workflow_run_id)
  end

  test "reviewer reads do not start a new cycle if the authorized run ends during the read",
       ctx do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    course_ids = [ctx.course.id, Ecto.UUID.dump!(ctx.course.id)]

    :ok =
      :telemetry.attach(
        handler_id,
        [:cgc2046, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "courses" and
               match?({:ok, %{num_rows: 1}}, metadata[:result]) and
               Enum.any?(metadata.params, &(&1 in course_ids)) do
            :telemetry.detach(handler_id)

            ctx.run
            |> Ash.Changeset.for_update(:cancel, %{}, actor: ctx.owner, tenant: ctx.workspace.id)
            |> Ash.update!(actor: ctx.owner, tenant: ctx.workspace.id)

            send(test_pid, {:review_run_cancelled, ctx.run.id})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    status = ctx.client |> call("get_prep_status", ctx.params) |> payload()
    assert_received {:review_run_cancelled, _}
    assert status["run_id"] == ctx.run.id

    assert Ash.get!(Cgc2046.Workflows.WorkflowRun, ctx.run.id, authorize?: false).status ==
             :cancelled

    assert is_nil(Prep.fetch_run(ctx.course.id, ctx.workspace.id))
    assert Ash.get!(Course, ctx.course.id, authorize?: false).workflow_run_id == ctx.run.id
  end

  test "a cancelled course stays hidden even with a stale active reviewer run", ctx do
    assert %{"run_id" => _} = ctx.client |> call("get_prep_status", ctx.params) |> payload()

    # 模拟存量活跃 run 与已取消课程的异常组合，验证草稿例外不会泄露已取消课程。
    Cgc2046.Repo.query!("UPDATE courses SET status = 'cancelled' WHERE id = $1", [
      Ecto.UUID.dump!(ctx.course.id)
    ])

    assert Prep.fetch_run(ctx.course.id, ctx.workspace.id).id == ctx.run.id
    assert_not_found(call(ctx.client, "get_prep_status", ctx.params), ctx.course.id)
  end

  defp draft(workspace, owner) do
    Course
    |> Ash.Changeset.for_create(:create, %{title: "Reviewer course"}, tenant: workspace.id)
    |> Ash.create!(actor: owner, tenant: workspace.id)
  end

  defp update_facts(run, patch, owner) do
    run
    |> Ash.Changeset.for_update(:update_prep_facts, %{facts: Map.merge(run.facts || %{}, patch)},
      tenant: run.workspace_id
    )
    |> Ash.update!(actor: owner, tenant: run.workspace_id)
  end

  defp post_mcp(token, body, session \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

    conn = if session, do: put_req_header(conn, "mcp-session-id", session), else: conn
    conn = post(conn, "/mcp", Jason.encode!(body))
    assert conn.status == 200
    conn
  end

  defp client(user) do
    {:ok, _token, plain} = Token.issue("reviewer status regression", user, :terminal)

    conn =
      post_mcp(plain, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "reviewer-status-test", version: "0.0.0"}
        }
      })

    [session] = get_resp_header(conn, "mcp-session-id")
    %{token: plain, session: session}
  end

  defp call(client, tool, params) do
    conn =
      post_mcp(
        client.token,
        %{
          jsonrpc: "2.0",
          id: System.unique_integer([:positive]),
          method: "tools/call",
          params: %{name: tool, arguments: params}
        },
        client.session
      )

    Jason.decode!(conn.resp_body)
  end

  defp payload(%{"result" => %{"content" => [%{"text" => text}]}}), do: Jason.decode!(text)

  defp assert_not_found(response, course_id) do
    assert %{"error" => %{"message" => message}} = response
    assert message == "course not found: #{course_id}"
  end
end
