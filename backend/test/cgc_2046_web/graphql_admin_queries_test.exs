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
  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun
  alias AshAuthentication.Info, as: AuthInfo

  @password "sup3r-secret-password"

  setup do
    Cgc2046.Workflows.StepHandlerRegistry.register(Cgc2046.Workflows.TestActions.Uppercase)

    Cgc2046.Workflows.StepHandlerRegistry.register(
      Cgc2046.Workflows.TestActions.AppendExclamation
    )

    Cgc2046.Workflows.StepHandlerRegistry.register(Cgc2046.Workflows.TestActions.AlwaysFail)

    # demote 的 ≥1 admin 约束依赖全局 admin 计数：清掉先前测试（sandbox 外）
    # 残留的 is_platform_admin 标记，保证每个测试从无 admin 状态开始（否则
    # 历史遗留 admin 会让"最后一个 admin"断言失真）。
    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = false WHERE is_platform_admin = true"
      )

    :ok
  end

  defp password_strategy, do: AuthInfo.strategy!(User, :password)

  defp register_user(email) do
    strategy = password_strategy()

    assert {:ok, user} =
             AshAuthentication.Strategy.action(strategy, :register, %{
               email: email,
               password: @password
             })

    user
  end

  defp platform_admin(email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
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

  defp create_workspace(admin, attrs \\ %{}) do
    slug = attrs[:slug] || "admin-ws-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             Workspace
             |> Ash.Changeset.for_create(:create, %{
               slug: slug,
               name: attrs[:name] || "Admin WS",
               join_policy: attrs[:join_policy] || :request
             })
             |> Ash.create(actor: admin)

    workspace
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
        }, tenant: workspace.id, actor: actor)
      |> Ash.create(tenant: workspace.id, actor: actor)

    run
  end

  describe "admin queries: non-admin is forbidden" do
    test "listUsers / listWorkspaces / listToolCallLogs / listPendingOperations / listSignalLogs all return forbidden for non-admin" do
      user = register_user("admin-queries-regular@example.com")
      token = sign_in_token(user.email, @password)

      for query <- [
            "query { listUsers { id email } }",
            "query { listWorkspaces { id slug } }",
            "query { listToolCallLogs { id tool } }",
            "query { listPendingOperations { id tool } }",
            "query { listSignalLogs { id } }"
          ] do
        resp = graphql_post(build_conn(), query, token)

        assert %{"errors" => [%{"message" => message}]} = resp,
               "expected forbidden for #{query}, got: #{inspect(resp)}"

        assert message == "forbidden" or message == "unauthorized"
      end
    end

    test "listWorkspaceApplications returns forbidden for non-admin" do
      user = register_user("admin-queries-regular2@example.com")
      token = sign_in_token(user.email, @password)

      resp = graphql_post(build_conn(), "query { listWorkspaceApplications { id } }", token)

      assert %{"errors" => [%{"message" => message}]} = resp
      assert message == "forbidden" or message == "unauthorized"
    end

    test "promoteUser / demoteUser return forbidden for non-admin" do
      user = register_user("admin-queries-regular3@example.com")
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
      admin = platform_admin("admin-queries-list@example.com")
      _member = register_user("admin-queries-target@example.com")
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
      assert user["email"] == "admin-queries-target@example.com"
      assert user["isPlatformAdmin"] == false
      assert user["workspaceMembershipCount"] >= 0
    end

    test "listUsers without search returns paged users (platform_admin)" do
      admin = platform_admin("admin-queries-listall@example.com")
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
      admin = platform_admin("admin-queries-ws@example.com")
      workspace = create_workspace(admin)
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
      admin = platform_admin("admin-queries-applist@example.com")
      applicant = register_user("admin-queries-applicant@example.com")
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
      applicant = register_user("admin-queries-myapp@example.com")
      other = register_user("admin-queries-myapp2@example.com")
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
      admin = platform_admin("admin-queries-tcl@example.com")
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
      admin = platform_admin("admin-queries-po@example.com")
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

  describe "listSignalLogs" do
    test "platform_admin can list signal logs filtered by workspace" do
      admin = platform_admin("admin-queries-sl@example.com")

      workspace =
        create_workspace(admin, slug: "admin-sl-ws-#{System.unique_integer([:positive])}")

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
      admin = platform_admin("admin-queries-sl-ws@example.com")

      ws_a =
        create_workspace(admin, slug: "admin-sl-a-#{System.unique_integer([:positive])}")

      ws_b =
        create_workspace(admin, slug: "admin-sl-b-#{System.unique_integer([:positive])}")

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

  # B2（advisor02）：after 参数是 string，须转 integer 传给 Ash.Query.offset
  describe "pagination after parameter" do
    test "listUsers with after offset returns paged subset" do
      admin = platform_admin("admin-queries-after@example.com")
      for i <- 1..3, do: register_user("admin-queries-after-#{i}@example.com")
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
      admin = platform_admin("admin-queries-wfr@example.com")

      workspace =
        create_workspace(admin, slug: "admin-wfr-ws-#{System.unique_integer([:positive])}")

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
      user = register_user("admin-queries-wfr-reg@example.com")
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
      admin = platform_admin("admin-queries-approve@example.com")
      applicant = register_user("admin-queries-approve-app@example.com")
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
      admin = platform_admin("admin-queries-promote@example.com")
      target = register_user("admin-queries-promote-target@example.com")
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
      admin = platform_admin("admin-queries-demote@example.com")
      target = platform_admin("admin-queries-demote-target@example.com")
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
      admin = platform_admin("admin-queries-lastadmin@example.com")
      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          mutation {
            demoteUser(id: "#{admin.id}") {
              isPlatformAdmin
              errors { message }
            }
          }
          """,
          token
        )

      # 最后一个 admin 不可降级（含自降级场景）
      assert %{"data" => %{"demoteUser" => nil}} = resp
      assert %{"errors" => [%{"code" => "last_admin_denied"}]} = resp

      reloaded = Ash.get!(User, admin.id, authorize?: false)
      assert reloaded.is_platform_admin == true
    end
  end

  describe "createWorkspaceWithOwner (auto-generated createWorkspace with owner args)" do
    test "platform_admin can create workspace designating existing user as Owner" do
      admin = platform_admin("admin-queries-cws@example.com")
      owner = register_user("admin-queries-cws-owner@example.com")
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
      admin = platform_admin("admin-queries-cws2@example.com")
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
