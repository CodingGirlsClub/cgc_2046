defmodule Cgc2046Web.GraphqlPlatformAuditTest do
  @moduledoc """
  平台审计面（H1 时间过滤 / L4 errorSummary 露出）：

  - 8 字段全量返回且类型正确；failed run 的 errorSummary = "workflow_failed"
    （常量白名单，天然脱敏），非 failed 返回 null
  - startedAfter/startedBefore 时间窗过滤生效
  - 非平台管理员 forbidden（负向）
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}

  defp token(email) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{
        "query" =>
          "mutation { signIn(login: \"#{email}\", password: \"#{Fixtures.password()}\") { id } }"
      })

    conn.resp_cookies["cgc_token"].value
  end

  # 布景而非被测对象：run 经域 action 创建（走租户/版本校验），started_at/status
  # 直接写库置位（状态机无直达任意终态 + 任意 started_at 的公开路径）。
  defp seed_run(workspace, actor, started_at, status) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研 workflow（审计布景 #{System.unique_integer([:positive])}）",
          type: :curriculum,
          input_schema: %{"topic" => "string"},
          node_def: %{"steps" => [%{"id" => "s1", "type" => "manual"}]},
          approval_timeout: 604_800
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    {:ok, run} =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: published.id,
          definition_version: published.version,
          input_snapshot: %{"topic" => "t1"}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE workflow_runs SET started_at = $1, status = $2 WHERE id = $3",
        [started_at, to_string(status), Ecto.UUID.dump!(run.id)]
      )

    run
  end

  defp audit_query(args \\ "") do
    """
    query {
      platformWorkflowAudit#{args} {
        id workspaceId definitionType status startedAt finishedAt insertedAt errorSummary
      }
    }
    """
  end

  defp audit_post(query, email) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token(email)}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  test "8 字段全量返回且类型正确；failed → workflow_failed，非 failed → null" do
    admin = Fixtures.platform_admin("audit-fields")
    workspace = Fixtures.create_workspace(admin)

    failed_run = seed_run(workspace, admin, ~U[2026-02-01 10:00:00Z], :failed)
    running_run = seed_run(workspace, admin, ~U[2026-02-02 10:00:00Z], :running)

    response = audit_post(audit_query(), admin.email)

    assert %{"data" => %{"platformWorkflowAudit" => rows}} = response
    assert length(rows) == 2

    for row <- rows do
      assert Map.keys(row) |> Enum.sort() ==
               ~w(definitionType errorSummary finishedAt id insertedAt startedAt status workspaceId)

      assert is_binary(row["id"])
      assert is_binary(row["workspaceId"])
      assert row["definitionType"] == "curriculum"
      assert is_binary(row["status"])
      assert is_binary(row["startedAt"])
      assert is_binary(row["insertedAt"])
      assert is_nil(row["finishedAt"])
    end

    by_id = Map.new(rows, &{&1["id"], &1})

    assert by_id[failed_run.id]["status"] == "failed"
    assert by_id[failed_run.id]["errorSummary"] == "workflow_failed"
    assert by_id[running_run.id]["status"] == "running"
    assert is_nil(by_id[running_run.id]["errorSummary"])
  end

  test "startedAfter/startedBefore 时间窗过滤生效（H1）" do
    admin = Fixtures.platform_admin("audit-window")
    workspace = Fixtures.create_workspace(admin)

    early = seed_run(workspace, admin, ~U[2026-02-01 10:00:00Z], :succeeded)
    late = seed_run(workspace, admin, ~U[2026-03-01 10:00:00Z], :succeeded)

    after_only =
      audit_post(audit_query("(startedAfter: \"2026-02-15T00:00:00Z\")"), admin.email)

    assert %{"data" => %{"platformWorkflowAudit" => [%{"id" => id}]}} = after_only
    assert id == late.id

    before_only =
      audit_post(audit_query("(startedBefore: \"2026-02-15T00:00:00Z\")"), admin.email)

    assert %{"data" => %{"platformWorkflowAudit" => [%{"id" => id}]}} = before_only
    assert id == early.id

    both =
      audit_post(
        audit_query(
          "(startedAfter: \"2026-01-01T00:00:00Z\", startedBefore: \"2027-01-01T00:00:00Z\")"
        ),
        admin.email
      )

    assert %{"data" => %{"platformWorkflowAudit" => rows}} = both
    assert Enum.map(rows, & &1["id"]) |> Enum.sort() == Enum.sort([early.id, late.id])
  end

  test "非平台管理员 forbidden（负向）" do
    user = Fixtures.register_user("audit-outsider")

    response = audit_post(audit_query(), user.email)

    assert %{"errors" => errors} = response
    assert Enum.any?(errors, &(&1["message"] == "forbidden"))
  end
end
