defmodule Cgc2046Web.GraphqlAdminQueriesTest do
  @moduledoc """
  Phase 5 admin GraphQL queries/mutations 验收测试（R3-R13 数据层）。

  经 /api/graphql 走完整 AshGraphQL pipeline（认证 + read policy）。覆盖：

  - listUsers / listWorkspaces / listToolCallLogs / listPendingOperations /
    listSignalLogs / listWorkspaceApplications：platform_admin 返回正确数据，
    非 admin forbidden
  - myWorkspaceApplications：申请人本人可见（R7a）
  - approveWorkspaceApplication（自动版）：创建 workspace + applicant 为 Owner
  - promoteUser / demoteUser：设置 is_platform_admin；demote 最后一个 admin 报错
  - createWorkspace（自动版，带 ownerUserId/ownerEmail）：owner 参数化生效
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  @password Fixtures.password()

  setup do
    Cgc2046.Workflows.StepHandlerRegistry.register(Cgc2046.Workflows.TestActions.Uppercase)

    Cgc2046.Workflows.StepHandlerRegistry.register(
      Cgc2046.Workflows.TestActions.AppendExclamation
    )

    Cgc2046.Workflows.StepHandlerRegistry.register(Cgc2046.Workflows.TestActions.AlwaysFail)

    # demote 的 ≥1 admin 约束依赖全局 admin 计数：清掉先前测试（sandbox 外）
    # 残留的 is_platform_admin 标记，保证每个测试从无 admin 状态开始（否则
    # 历史遗留 admin 会让"最后一个 admin"断言失真）。
    Fixtures.reset_platform_admins()

    :ok
  end

  defp sign_in_token(email, password) do
    query = """
    mutation {
      signIn(email: "#{email}", password: "#{password}") {
        id
      }
    }
    """

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/graphql", %{"query" => query})

    assert %{"data" => %{"signIn" => %{"id" => _id}}} = json_response(conn, 200)
    conn.resp_cookies["cgc_token"].value
  end

  defp graphql_post(conn, query, token) do
    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", %{"query" => query})
    |> json_response(200)
  end

  defp create_workspace_application(user, attrs \\ %{}) do
    changes =
      Map.merge(
        %{
          applicant_id: user.id,
          name: "App WS",
          slug: "admin-app-#{System.unique_integer([:positive])}",
          purpose: "测试申请"
        },
        attrs
      )

    {:ok, application} =
      WorkspaceApplication
      |> Ash.Changeset.for_create(:create, changes)
      |> Ash.create(actor: user)

    application
  end

  # 造 ToolCallLog / PendingOperation 审计记录（params 内含 workspace_id，D5 JSONB）
  defp create_tool_call_log(attrs) do
    {:ok, log} =
      ToolCallLog
      |> Ash.Changeset.for_create(
        :log,
        Map.merge(
          %{
            user_id: Ecto.UUID.generate(),
            tool: "get_workspace_context",
            params: %{"workspace_id" => Ecto.UUID.generate()},
            result_status: :ok
          },
          attrs
        )
      )
      |> Ash.create(authorize?: false)

    log
  end

  defp create_pending_operation(attrs) do
    {:ok, op} =
      PendingOperation
      |> Ash.Changeset.for_create(
        :pend,
        Map.merge(
          %{
            user_id: Ecto.UUID.generate(),
            tool: "create_invitation",
            params: %{"workspace_id" => Ecto.UUID.generate()},
            summary: "创建邀请"
          },
          attrs
        )
      )
      |> Ash.create(authorize?: false)

    op
  end

  defp create_signal_log(workspace, attrs \\ %{}) do
    {:ok, signal} =
      SignalLog
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            run_id: Ecto.UUID.generate(),
            signal_type: :state_change,
            payload: %{},
            actor_id: Ecto.UUID.generate()
          },
          attrs
        ),
        tenant: workspace.id
      )
      |> Ash.create(tenant: workspace.id, authorize?: false)

    signal
  end

  # WorkflowRun 测试数据：建 definition → publish → create run（tenant 隔离）
  defp create_definition(workspace, actor) do
    defaults = %{
      name: "admin queries wf",
      type: :research,
      input_schema: %{"topic" => "string"},
      node_def: %{
        "steps" => [
          %{
            "id" => "uppercase",
            "type" => "auto",
            "action" => "Elixir.Cgc2046.Workflows.TestActions.Uppercase"
          }
        ]
      },
      approval_timeout: 604_800
    }

    {:ok, definition} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(:create, defaults, tenant: workspace.id, actor: actor)
      |> Ash.create(tenant: workspace.id, actor: actor)

    definition
  end

  defp publish_definition(definition, workspace, actor) do
    {:ok, published} =
      definition
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  defp create_workflow_run(workspace, actor, definition) do
    {:ok, run} =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: definition.id,
          definition_version: definition.version,
          input_snapshot: %{"topic" => "t1"}
        },
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    run
  end

  describe "admin queries: non-admin is forbidden" do
    test "listUsers / listWorkspaces / listToolCallLogs / listPendingOperations / listSignalLogs all return forbidden for non-admin" do
      user = Fixtures.register_user("admin-queries-regular")
      token = sign_in_token(user.email, @password)

      for query <- [
            "query { listUsers { id email } }",
            "query { listWorkspaces { id slug } }",
            "query { listToolCallLogs { id tool } }",
            "query { listPendingOperations { id tool } }",
            "query { listSignalLogs { id } }",
            "query { listAdminActionLogs { id action } }"
          ] do
        resp = graphql_post(build_conn(), query, token)

        assert %{"errors" => [%{"message" => message}]} = resp,
               "expected forbidden for #{query}, got: #{inspect(resp)}"

        assert message == "forbidden" or message == "unauthorized"
      end
    end

    test "listWorkspaceApplications returns forbidden for non-admin" do
      user = Fixtures.register_user("admin-queries-regular2")
      token = sign_in_token(user.email, @password)

      resp = graphql_post(build_conn(), "query { listWorkspaceApplications { id } }", token)

      assert %{"errors" => [%{"message" => message}]} = resp
      assert message == "forbidden" or message == "unauthorized"
    end

    test "promoteUser / demoteUser return forbidden for non-admin" do
      user = Fixtures.register_user("admin-queries-regular3")
      token = sign_in_token(user.email, @password)

      for query <- [
            "mutation { promoteUser(id: \"#{Ecto.UUID.generate()}\") { isPlatformAdmin } }",
            "mutation { demoteUser(id: \"#{Ecto.UUID.generate()}\") { isPlatformAdmin } }"
          ] do
        resp = graphql_post(build_conn(), query, token)

        assert %{"errors" => [%{"message" => message}]} = resp
        assert message == "forbidden" or message == "unauthorized"
      end
    end
  end

  describe "listUsers" do
    test "platform_admin can list users with membership summary" do
      admin = Fixtures.platform_admin("admin-queries-list")
      member = Fixtures.register_user("admin-queries-target")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listUsers(search: "target", first: 10) {
              id email displayName isPlatformAdmin insertedAt workspaceMembershipCount
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listUsers" => users}} = resp
      assert [user] = users
      assert user["email"] == to_string(member.email)
      assert user["isPlatformAdmin"] == false
      assert user["workspaceMembershipCount"] >= 0
    end

    test "listUsers without search returns paged users (platform_admin)" do
      admin = Fixtures.platform_admin("admin-queries-listall")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          "query { listUsers(first: 5) { id email } }",
          token
        )

      assert %{"data" => %{"listUsers" => users}} = resp
      assert is_list(users)
      assert length(users) <= 5
    end
  end

  describe "listWorkspaces" do
    test "platform_admin can list all workspaces" do
      admin = Fixtures.platform_admin("admin-queries-ws")
      workspace = Fixtures.create_workspace(admin)
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkspaces(search: "#{workspace.slug}", first: 10) {
              id slug name joinPolicy sponsorshipEnabled insertedAt memberCount
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkspaces" => [ws]}} = resp
      assert ws["slug"] == workspace.slug
      assert ws["name"] == workspace.name
      assert ws["joinPolicy"] == "request"
      assert ws["memberCount"] >= 1
    end
  end

  describe "listWorkspaceApplications" do
    test "platform_admin can list applications with status filter" do
      admin = Fixtures.platform_admin("admin-queries-applist")
      applicant = Fixtures.register_user("admin-queries-applicant")
      application = create_workspace_application(applicant)
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkspaceApplications(status: "pending", first: 10) {
              id applicantId name slug purpose status rejectionReason
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkspaceApplications" => apps}} = resp
      assert Enum.any?(apps, &(&1["id"] == to_string(application.id)))
      assert Enum.all?(apps, &(&1["status"] == "pending"))
    end
  end

  describe "myWorkspaceApplications" do
    test "applicant sees only own applications (R7a)" do
      applicant = Fixtures.register_user("admin-queries-myapp")
      other = Fixtures.register_user("admin-queries-myapp2")
      _mine = create_workspace_application(applicant)
      create_workspace_application(other)
      token = sign_in_token(applicant.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            myWorkspaceApplications {
              id status rejectionReason
            }
          }
          """,
          token
        )

      assert %{"data" => %{"myWorkspaceApplications" => apps}} = resp
      # 只看到自己的申请（applicant 只有一条）
      assert length(apps) == 1
    end
  end

  describe "listToolCallLogs / listPendingOperations (D5 JSONB workspace filter)" do
    test "platform_admin can list tool call logs filtered by workspace_id in params JSONB" do
      admin = Fixtures.platform_admin("admin-queries-tcl")
      ws_id = Ecto.UUID.generate()
      create_tool_call_log(%{params: %{"workspace_id" => ws_id}, tool: "filtered_tool"})

      create_tool_call_log(%{
        params: %{"workspace_id" => Ecto.UUID.generate()},
        tool: "other_tool"
      })

      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listToolCallLogs(workspaceId: "#{ws_id}", first: 10) {
              id tool resultStatus
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listToolCallLogs" => logs}} = resp
      assert [log] = logs
      assert log["tool"] == "filtered_tool"
    end

    test "platform_admin can list pending operations filtered by workspace_id in params JSONB" do
      admin = Fixtures.platform_admin("admin-queries-po")
      ws_id = Ecto.UUID.generate()
      create_pending_operation(%{params: %{"workspace_id" => ws_id}, tool: "filtered_op"})

      create_pending_operation(%{
        params: %{"workspace_id" => Ecto.UUID.generate()},
        tool: "other_op"
      })

      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listPendingOperations(workspaceId: "#{ws_id}", first: 10) {
              id tool summary
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listPendingOperations" => ops}} = resp
      assert [op] = ops
      assert op["tool"] == "filtered_op"
    end
  end

  describe "listAdminActionLogs (#116 R10a)" do
    test "platform_admin can list admin action logs and filter by action" do
      admin = Fixtures.platform_admin("admin-queries-aal")

      # 资源层直接创建（带 actor）→ 落一行 workspace_create 治理留痕
      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "gql-aal-#{System.unique_integer([:positive])}",
          name: "GQL AAL"
        })
        |> Ash.create(actor: admin)

      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(first: 10) {
              id actorId action targetType targetId result insertedAt
            }
          }
          """,
          token
        )

      # 断言一律按 target_id 收敛到本测试自建行，不断言全局行数 ——
      # 测试 DB 会累积其他用例经非沙箱上下文提交的留痕行。
      # first: 10 + inserted_at desc，本测试新建的行最新必在首页。
      assert %{"data" => %{"listAdminActionLogs" => logs}} = resp

      log = Enum.find(logs, &(&1["targetId"] == workspace.id))
      assert log, "expected workspace_create log for #{workspace.id} on first page"
      assert log["action"] == "workspace_create"
      assert log["actorId"] == admin.id
      assert log["targetType"] == "workspace"
      assert log["result"] == "success"

      # action 过滤：返回行全部命中过滤条件，且本测试的 workspace_create 行被滤除
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(action: "application_approve", first: 10) { id action targetId }
          }
          """,
          token
        )

      assert %{"data" => %{"listAdminActionLogs" => approve_logs}} = resp
      assert Enum.all?(approve_logs, &(&1["action"] == "application_approve"))
      refute Enum.any?(approve_logs, &(&1["targetId"] == workspace.id))

      # action 过滤命中 → 含本测试行且全部命中过滤条件
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(action: "workspace_create", first: 10) { id action targetId }
          }
          """,
          token
        )

      assert %{"data" => %{"listAdminActionLogs" => filtered_logs}} = resp
      assert Enum.all?(filtered_logs, &(&1["action"] == "workspace_create"))
      assert Enum.any?(filtered_logs, &(&1["targetId"] == workspace.id))
    end
  end

  describe "listSignalLogs" do
    test "platform_admin can list signal logs filtered by workspace" do
      admin = Fixtures.platform_admin("admin-queries-sl")

      workspace =
        Fixtures.create_workspace(admin, %{
          slug: "admin-sl-ws-#{System.unique_integer([:positive])}"
        })

      _signal = create_signal_log(workspace)
      token = sign_in_token(admin.email, @password)

      # 无 workspaceId 时返回全部（platform_admin）
      resp =
        graphql_post(
          build_conn(),
          "query { listSignalLogs(first: 10) { id } }",
          token
        )

      assert %{"data" => %{"listSignalLogs" => signals}} = resp
      assert is_list(signals)
    end

    # B1（advisor02）：SignalLog 有真实 workspace_id 列（非 params JSONB），
    # workspaceId 过滤必须走真实列（否则 SQL 访问不存在的 params 列报错）
    test "platform_admin can list signal logs filtered by workspaceId (real column)" do
      admin = Fixtures.platform_admin("admin-queries-sl-ws")

      ws_a =
        Fixtures.create_workspace(admin, %{
          slug: "admin-sl-a-#{System.unique_integer([:positive])}"
        })

      ws_b =
        Fixtures.create_workspace(admin, %{
          slug: "admin-sl-b-#{System.unique_integer([:positive])}"
        })

      create_signal_log(ws_a, %{signal_type: :approval_ok})
      create_signal_log(ws_b, %{signal_type: :rejected})
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listSignalLogs(workspaceId: "#{ws_a.id}", first: 10) {
              id signalType
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listSignalLogs" => signals}} = resp
      assert is_list(signals)
      assert length(signals) == 1
      assert hd(signals)["signalType"] == "approval_ok"
    end
  end

  # #117：status / signal_type / inserted_after / inserted_before 组合筛选。
  # inserted_at / expires_at 由资源 action 自动控制，测试经 SQL backdate 造时间边界
  # （与 setup 的 UPDATE users 先例一致——非沙箱全局状态，断言一律收敛到本测试自建行）。
  describe "admin queries: status/time filters (#117)" do
    defp backdate(table, id, dt) do
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE #{table} SET inserted_at = $1 WHERE id = $2",
        [dt, Ecto.UUID.dump!(id)]
      )
    end

    defp iso(dt), do: DateTime.to_iso8601(dt)

    test "listToolCallLogs: status maps to result_status; workspace+status+time combo" do
      admin = Fixtures.platform_admin("admin-queries-f-tcl")
      ws_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      target =
        create_tool_call_log(%{
          params: %{"workspace_id" => ws_id},
          tool: "combo_tool",
          result_status: :ok
        })

      backdate("mcp_tool_call_logs", target.id, DateTime.add(now, -3 * 86_400, :second))

      # 干扰：同 ws 不同状态 / 同状态不同 ws（默认随机 ws）/ 同 ws 同状态但时间新鲜
      create_tool_call_log(%{params: %{"workspace_id" => ws_id}, result_status: :forbidden})
      create_tool_call_log(%{tool: "combo_tool", result_status: :ok})

      fresh =
        create_tool_call_log(%{
          params: %{"workspace_id" => ws_id},
          tool: "combo_tool",
          result_status: :ok
        })

      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listToolCallLogs(
              workspaceId: "#{ws_id}"
              status: "ok"
              insertedAfter: "#{iso(DateTime.add(now, -4 * 86_400, :second))}"
              insertedBefore: "#{iso(DateTime.add(now, -2 * 86_400, :second))}"
              first: 10
            ) { id tool resultStatus }
          }
          """,
          token
        )

      assert %{"data" => %{"listToolCallLogs" => [log]}} = resp
      assert log["id"] == target.id
      assert log["resultStatus"] == "ok"

      # 时间窗挪到 backdate 之后 → 只剩 fresh 行
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listToolCallLogs(
              workspaceId: "#{ws_id}"
              status: "ok"
              insertedAfter: "#{iso(DateTime.add(now, -1 * 86_400, :second))}"
              first: 10
            ) { id }
          }
          """,
          token
        )

      assert %{"data" => %{"listToolCallLogs" => logs}} = resp
      assert Enum.map(logs, & &1["id"]) == [fresh.id]

      # 非法 status 静默忽略（to_existing_atom rescue 回退），不 500、不过滤
      resp =
        graphql_post(
          build_conn(),
          ~s|query { listToolCallLogs(status: "no_such_atom_xyz", first: 10) { id } }|,
          token
        )

      assert %{"data" => %{"listToolCallLogs" => logs}} = resp
      assert is_list(logs)
    end

    test "listPendingOperations: status enums + derived expired special-case" do
      admin = Fixtures.platform_admin("admin-queries-f-po")
      ws_id = Ecto.UUID.generate()

      pending_op = create_pending_operation(%{params: %{"workspace_id" => ws_id}})
      confirmed_op = create_pending_operation(%{params: %{"workspace_id" => ws_id}})

      # :pend 不接受 status/expires_at（accept 白名单 + change 自动写），SQL 直改造态
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE mcp_pending_operations SET status = $1 WHERE id = $2",
        ["confirmed", Ecto.UUID.dump!(confirmed_op.id)]
      )

      expired_op = create_pending_operation(%{params: %{"workspace_id" => ws_id}})

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE mcp_pending_operations SET expires_at = $1 WHERE id = $2",
        [DateTime.add(DateTime.utc_now(), -60, :second), Ecto.UUID.dump!(expired_op.id)]
      )

      token = sign_in_token(admin.email, @password)

      # expired 特判：status == :pending 且 expires_at < now → 只中过期行
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listPendingOperations(workspaceId: "#{ws_id}", status: "expired", first: 10) { id }
          }
          """,
          token
        )

      assert %{"data" => %{"listPendingOperations" => [op]}} = resp
      assert op["id"] == expired_op.id

      # pending 按落库语义：未过期 + 已过期两行都中（expired 是读时派生视图）
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listPendingOperations(workspaceId: "#{ws_id}", status: "pending", first: 10) { id }
          }
          """,
          token
        )

      assert %{"data" => %{"listPendingOperations" => ops}} = resp
      assert Enum.sort(Enum.map(ops, & &1["id"])) == Enum.sort([pending_op.id, expired_op.id])

      # confirmed 单行
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listPendingOperations(workspaceId: "#{ws_id}", status: "confirmed", first: 10) { id }
          }
          """,
          token
        )

      assert %{"data" => %{"listPendingOperations" => [op]}} = resp
      assert op["id"] == confirmed_op.id
    end

    test "listSignalLogs: signal_type + time range combo" do
      admin = Fixtures.platform_admin("admin-queries-f-sl")

      workspace =
        Fixtures.create_workspace(admin, %{
          slug: "admin-f-sl-#{System.unique_integer([:positive])}"
        })

      now = DateTime.utc_now()
      target = create_signal_log(workspace, %{signal_type: "workflow.approval"})
      backdate("signal_logs", target.id, DateTime.add(now, -3 * 86_400, :second))
      create_signal_log(workspace, %{signal_type: "workflow.rejected"})
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listSignalLogs(
              workspaceId: "#{workspace.id}"
              signalType: "workflow.approval"
              insertedAfter: "#{iso(DateTime.add(now, -4 * 86_400, :second))}"
              insertedBefore: "#{iso(DateTime.add(now, -2 * 86_400, :second))}"
              first: 10
            ) { id signalType }
          }
          """,
          token
        )

      assert %{"data" => %{"listSignalLogs" => [signal]}} = resp
      assert signal["id"] == target.id
    end

    test "listAdminActionLogs: time range filter" do
      admin = Fixtures.platform_admin("admin-queries-f-aal")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "gql-f-aal-#{System.unique_integer([:positive])}",
          name: "GQL F AAL"
        })
        |> Ash.create(actor: admin)

      now = DateTime.utc_now()

      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE admin_action_logs SET inserted_at = $1 WHERE target_id = $2",
        [DateTime.add(now, -3 * 86_400, :second), Ecto.UUID.dump!(workspace.id)]
      )

      token = sign_in_token(admin.email, @password)

      # 时间窗覆盖 backdate 行 → 含本测试行
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(
              action: "workspace_create"
              insertedAfter: "#{iso(DateTime.add(now, -4 * 86_400, :second))}"
              insertedBefore: "#{iso(DateTime.add(now, -2 * 86_400, :second))}"
              first: 50
            ) { id targetId }
          }
          """,
          token
        )

      assert %{"data" => %{"listAdminActionLogs" => logs}} = resp
      assert Enum.any?(logs, &(&1["targetId"] == workspace.id))

      # 时间窗在 backdate 之后 → 本测试行被排除
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(
              action: "workspace_create"
              insertedAfter: "#{iso(DateTime.add(now, -1 * 86_400, :second))}"
              first: 50
            ) { id targetId }
          }
          """,
          token
        )

      assert %{"data" => %{"listAdminActionLogs" => logs}} = resp
      refute Enum.any?(logs, &(&1["targetId"] == workspace.id))
    end

    test "listWorkflowRuns: workspaceId + status combo (auto filter)" do
      admin = Fixtures.platform_admin("admin-queries-f-wfr")

      workspace =
        Fixtures.create_workspace(admin, %{
          slug: "admin-f-wfr-#{System.unique_integer([:positive])}"
        })

      definition = create_definition(workspace, admin)
      publish_definition(definition, workspace, admin)
      run = create_workflow_run(workspace, admin, definition)
      token = sign_in_token(admin.email, @password)

      # create 落 pending 态：workspaceId + status 组合命中；换个状态则空
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(
              filter: { workspaceId: { eq: "#{workspace.id}" }, status: { eq: "pending" } }
              first: 10
            ) { results { id status } }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => runs}}} = resp
      assert Enum.map(runs, & &1["id"]) == [run.id]

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(
              filter: { workspaceId: { eq: "#{workspace.id}" }, status: { eq: "succeeded" } }
              first: 10
            ) { results { id } }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => []}}} = resp
    end

    test "listWorkflowRuns: startedAt time range (LOW-2; NULL started_at excluded = LOW-1 语义固化)" do
      admin = Fixtures.platform_admin("admin-queries-f-wfr-time")

      workspace =
        Fixtures.create_workspace(admin, %{
          slug: "admin-f-wfr-t-#{System.unique_integer([:positive])}"
        })

      definition = create_definition(workspace, admin)
      publish_definition(definition, workspace, admin)
      run = create_workflow_run(workspace, admin, definition)
      never_started = create_workflow_run(workspace, admin, definition)

      now = DateTime.utc_now()

      # create 不落 started_at（start action 才写），SQL backdate 造时间边界
      Ecto.Adapters.SQL.query!(
        Cgc2046.Repo,
        "UPDATE workflow_runs SET started_at = $1 WHERE id = $2",
        [DateTime.add(now, -3 * 86_400, :second), Ecto.UUID.dump!(run.id)]
      )

      token = sign_in_token(admin.email, @password)

      # 时间窗覆盖 backdate 行 → 仅命中它；started_at NULL 的 run 被排除
      # （SQL 比较对 NULL 求值 NULL/false——LOW-1 的 tab 语义差异固化为断言）
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(
              filter: {
                workspaceId: { eq: "#{workspace.id}" }
                startedAt: {
                  greaterThanOrEqual: "#{iso(DateTime.add(now, -4 * 86_400, :second))}"
                  lessThanOrEqual: "#{iso(DateTime.add(now, -2 * 86_400, :second))}"
                }
              }
              first: 10
            ) { results { id } }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => [hit]}}} = resp
      assert hit["id"] == run.id

      # 时间窗在 backdate 之后 → 空
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(
              filter: {
                workspaceId: { eq: "#{workspace.id}" }
                startedAt: { greaterThanOrEqual: "#{iso(DateTime.add(now, -1 * 86_400, :second))}" }
              }
              first: 10
            ) { results { id } }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => []}}} = resp

      # 对照：无时间范围时两行都在（排除确由时间过滤造成）
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(filter: { workspaceId: { eq: "#{workspace.id}" } }, first: 10) {
              results { id }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => runs}}} = resp
      assert Enum.sort(Enum.map(runs, & &1["id"])) == Enum.sort([run.id, never_started.id])
    end
  end

  # B2（advisor02）：after 参数是 string，须转 integer 传给 Ash.Query.offset
  describe "pagination after parameter" do
    test "listUsers with after offset returns paged subset" do
      admin = Fixtures.platform_admin("admin-queries-after")
      for i <- 1..3, do: Fixtures.register_user("admin-queries-after-#{i}")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          "query { listUsers(first: 2, after: \"1\") { id email } }",
          token
        )

      assert %{"data" => %{"listUsers" => users}} = resp
      assert is_list(users)
      # first=2 + offset=1 → 返回最多 2 条（不是从第 1 条起而是第 2 条起）
      assert length(users) <= 2
    end
  end

  # S1（advisor02）：listWorkflowRuns 用自动版（WorkflowRun 已暴露同名 query，
  # filter.workspaceId.eq 真实列过滤；platform_admin read policy 已解锁）。
  describe "listWorkflowRuns (auto-generated)" do
    test "platform_admin can list workflow runs filtered by workspace" do
      admin = Fixtures.platform_admin("admin-queries-wfr")

      workspace =
        Fixtures.create_workspace(admin, %{
          slug: "admin-wfr-ws-#{System.unique_integer([:positive])}"
        })

      definition = create_definition(workspace, admin)
      publish_definition(definition, workspace, admin)
      create_workflow_run(workspace, admin, definition)
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listWorkflowRuns(filter: { workspaceId: { eq: "#{workspace.id}" } }, first: 10) {
              results {
                id workspaceId status
              }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => runs}}} = resp
      assert is_list(runs)
      assert length(runs) == 1
      assert hd(runs)["workspaceId"] == to_string(workspace.id)
    end

    test "listWorkflowRuns returns empty for non-admin (filter + policy)" do
      user = Fixtures.register_user("admin-queries-wfr-reg")
      token = sign_in_token(user.email, @password)

      resp =
        graphql_post(
          build_conn(),
          "query { listWorkflowRuns(first: 10) { results { id } } }",
          token
        )

      assert %{"data" => %{"listWorkflowRuns" => %{"results" => runs}}} = resp
      assert is_list(runs)
    end
  end

  describe "approveWorkspaceApplication (auto-generated)" do
    test "platform_admin approve creates workspace with applicant as Owner" do
      admin = Fixtures.platform_admin("admin-queries-approve")
      applicant = Fixtures.register_user("admin-queries-approve-app")
      application = create_workspace_application(applicant)
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            approveWorkspaceApplication(id: "#{application.id}") {
              result {
                id status
              }
              errors { message }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"approveWorkspaceApplication" => %{"result" => result}}} = resp
      assert result["status"] == "approved"

      # workspace 已创建 + applicant 为 Owner
      assert {:ok, workspace} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: application.slug})
               |> Ash.read_one(authorize?: false)

      assert MembershipContext.role_names(applicant, workspace.id) == [:owner]
    end
  end

  describe "promoteUser / demoteUser" do
    test "platform_admin can promote a user" do
      admin = Fixtures.platform_admin("admin-queries-promote")
      target = Fixtures.register_user("admin-queries-promote-target")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            promoteUser(id: "#{target.id}") {
              isPlatformAdmin
              errors { message }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"promoteUser" => %{"isPlatformAdmin" => true}}} = resp

      reloaded = Ash.get!(User, target.id, authorize?: false)
      assert reloaded.is_platform_admin == true
    end

    test "platform_admin can demote a non-last admin" do
      admin = Fixtures.platform_admin("admin-queries-demote")
      target = Fixtures.platform_admin("admin-queries-demote-target")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            demoteUser(id: "#{target.id}") {
              isPlatformAdmin
              errors { message }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"demoteUser" => %{"isPlatformAdmin" => false}}} = resp

      reloaded = Ash.get!(User, target.id, authorize?: false)
      assert reloaded.is_platform_admin == false
    end

    test "demoteUser rejects when target is the last remaining platform admin" do
      admin = Fixtures.platform_admin("admin-queries-lastadmin")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            demoteUser(id: "#{admin.id}") {
              isPlatformAdmin
              errors { message code }
            }
          }
          """,
          token
        )

      # 最后一个 admin 不可降级（含自降级场景）；错误走 payload errors 通道
      assert %{"data" => %{"demoteUser" => %{"errors" => [%{"code" => "last_admin_denied"}]}}} =
               resp

      reloaded = Ash.get!(User, admin.id, authorize?: false)
      assert reloaded.is_platform_admin == true
    end

    test "demoteUser rejects when target is not a platform admin" do
      admin = Fixtures.platform_admin("admin-queries-notadmin")
      target = Fixtures.register_user("admin-queries-notadmin-target")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            demoteUser(id: "#{target.id}") {
              isPlatformAdmin
              errors { message code }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"demoteUser" => %{"errors" => [%{"code" => "not_platform_admin"}]}}} =
               resp

      reloaded = Ash.get!(User, target.id, authorize?: false)
      assert reloaded.is_platform_admin == false
    end

    test "demoteUser returns top-level not_found error for a nonexistent id" do
      admin = Fixtures.platform_admin("admin-queries-demote-notfound")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            demoteUser(id: "#{Ecto.UUID.generate()}") {
              isPlatformAdmin
              errors { message code }
            }
          }
          """,
          token
        )

      # action 之前的失败（Ash.get not-found）走 top-level error 通道，
      # 与 action 之内领域错误的 payload 通道分界
      assert %{"data" => %{"demoteUser" => nil}} = resp
      assert %{"errors" => [%{"code" => "not_found"}]} = resp
    end
  end

  describe "createWorkspaceWithOwner (auto-generated createWorkspace with owner args)" do
    test "platform_admin can create workspace designating existing user as Owner" do
      admin = Fixtures.platform_admin("admin-queries-cws")
      owner = Fixtures.register_user("admin-queries-cws-owner")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            createWorkspace(input: {
              slug: "admin-cws-#{System.unique_integer([:positive])}",
              name: "CWS WS",
              joinPolicy: "request",
              ownerUserId: "#{owner.id}"
            }) {
              result {
                id slug name
              }
              metadata {
                ownerInvitationToken
              }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"createWorkspace" => %{"result" => result}}} = resp
      assert result["metadata"] == nil

      assert {:ok, workspace} =
               Workspace
               |> Ash.Query.for_read(:get_by_slug, %{slug: result["slug"]})
               |> Ash.read_one(authorize?: false)

      assert MembershipContext.role_names(owner, workspace.id) == [:owner]
    end

    test "platform_admin can create workspace with owner_email -> pending-owner invitation token returned" do
      admin = Fixtures.platform_admin("admin-queries-cws2")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            createWorkspace(input: {
              slug: "admin-cws2-#{System.unique_integer([:positive])}",
              name: "CWS2 WS",
              joinPolicy: "request",
              ownerEmail: "pending-owner-cws@example.com"
            }) {
              result {
                id slug name
              }
              metadata {
                ownerInvitationToken
              }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"createWorkspace" => %{"metadata" => metadata}}} = resp
      refute is_nil(metadata["ownerInvitationToken"])

      # pending-owner 邀请已建（target_email 匹配 + preauthorized [:owner]）
      require Ash.Query

      assert {:ok, invitations} =
               Invitation
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(target_email == "pending-owner-cws@example.com")
               |> Ash.read(authorize?: false)

      assert [invitation] = invitations
      assert invitation.preauthorized_role_names == [:owner]
    end
  end
end
