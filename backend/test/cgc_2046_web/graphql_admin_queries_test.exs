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

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.Workspace
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Mcp.PendingOperation
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowDefinition
  alias Cgc2046.Workflows.WorkflowRun

  require Ash.Query

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
      signIn(login: "#{email}", password: "#{password}") {
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
      type: :curriculum,
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
            # #607：metadata 字段与列表同 gate（非 admin 连投影读面都拿不到）
            "query { listAdminActionLogs { id action metadata { ruleKey valueAfterJson } } }"
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

  # #607：metadata 白名单投影读面（表在 Cgc2046Web.GraphqlSchema 顶部）
  describe "listAdminActionLogs metadata 白名单投影 (#607)" do
    test "platform_admin 能在读面看到 value_before → value_after 与 locked 翻转" do
      admin = Fixtures.platform_admin("admin-queries-aal-md")
      initiative = create_rule_initiative(admin, "gql-md")

      {:ok, rule} =
        create_initiative_rule(
          initiative,
          admin,
          :deposit,
          %{enabled: true, amount_cents: 6900},
          true
        )

      {:ok, _} =
        rule
        |> Ash.Changeset.for_update(:update, %{
          value: %{enabled: true, amount_cents: 9900},
          locked: false
        })
        |> Ash.update(actor: admin)

      token = sign_in_token(admin.email, @password)

      meta =
        token
        |> list_rule_logs()
        |> rule_metadata_rows(initiative.id)
        |> Enum.find(&(decoded(&1["valueAfterJson"])["amount_cents"] == 9900))

      assert meta, "expected the rule-update row for #{initiative.id}"
      assert meta["ruleKey"] == "deposit"
      # locked 翻转（#607 验收：值前后 + locked 翻转）
      assert meta["locked"] == false
      assert meta["lockedBefore"] == true

      assert decoded(meta["valueBeforeJson"]) == %{"enabled" => true, "amount_cents" => 6900}
      assert decoded(meta["valueAfterJson"]) == %{"enabled" => true, "amount_cents" => 9900}
      # 键序 = 二级白名单次序（前端直接按序渲染，不再抄一份键名清单）
      assert json_keys(meta["valueAfterJson"]) == ["enabled", "amount_cents"]
      refute meta["valueBeforeOmitted"]
      refute meta["valueAfterOmitted"]
    end

    test ":create（新建规则）时前值字段为 null —— 前端据此渲染「新建」" do
      admin = Fixtures.platform_admin("admin-queries-aal-md-create")
      initiative = create_rule_initiative(admin, "gql-md-create")

      {:ok, _rule} =
        create_initiative_rule(initiative, admin, :min_participants, %{count: 8}, false)

      token = sign_in_token(admin.email, @password)
      assert [meta] = token |> list_rule_logs() |> rule_metadata_rows(initiative.id)

      assert meta["ruleKey"] == "min_participants"
      # null ⇔ 新建（契约：value_before 仅在 :create 为 nil）
      assert meta["valueBeforeJson"] == nil
      assert meta["lockedBefore"] == nil
      assert decoded(meta["valueAfterJson"]) == %{"count" => 8}
      assert meta["locked"] == false
    end

    test "白名单外 metadata 键与 value 内白名单外键都不出现在读面（结构性防泄露）" do
      admin = Fixtures.platform_admin("admin-queries-aal-md-leak")
      initiative = create_rule_initiative(admin, "gql-md-leak")

      # 直连写入面造行：模拟「未来某条路径往 metadata / 规则值里塞了 PII 或自由文本」
      {:ok, _} =
        AdminActionLog.log(%{
          actor_id: admin.id,
          action: :initiative_rule_update,
          target_type: :initiative,
          target_id: initiative.id,
          metadata: %{
            initiative_id: initiative.id,
            rule_key: "deposit",
            locked: true,
            locked_before: false,
            value_before: %{enabled: true, amount_cents: 6900, internal_note: "before-secret"},
            value_after: %{enabled: true, amount_cents: 9900, internal_note: "after-secret"},
            email: "leak@example.com",
            target_email: "leak2@example.com",
            rejection_reason: "leak-reason-自由文本"
          }
        })

      token = sign_in_token(admin.email, @password)
      resp = list_rule_logs(token)

      # 负向断言打在原始响应体上：白名单外串一个都不许出现
      body = Jason.encode!(resp)

      for sentinel <- [
            "leak@example.com",
            "leak2@example.com",
            "leak-reason-自由文本",
            "internal_note",
            "before-secret",
            "after-secret"
          ] do
        refute body =~ sentinel, "读面泄露了白名单外内容: #{sentinel}"
      end

      assert [meta] = rule_metadata_rows(resp, initiative.id)

      # 二级白名单：值内的白名单外键被投影掉，且省略必须可见（不静默截断）
      assert decoded(meta["valueAfterJson"]) == %{"enabled" => true, "amount_cents" => 9900}
      assert meta["valueBeforeOmitted"] == true
      assert meta["valueAfterOmitted"] == true
    end

    test "值不是标量（嵌套 map）时按标量门省略，不当内容透传" do
      admin = Fixtures.platform_admin("admin-queries-aal-md-nested")
      initiative = create_rule_initiative(admin, "gql-md-nested")

      # 键名命中二级白名单（enabled），但值是嵌套结构：键名白名单约束不了内容，
      # 标量门必须把它挡掉并标 omitted（否则嵌套内容原样带出）
      {:ok, _} =
        AdminActionLog.log(%{
          actor_id: admin.id,
          action: :initiative_rule_update,
          target_type: :initiative,
          target_id: initiative.id,
          metadata: %{
            initiative_id: initiative.id,
            rule_key: "deposit",
            locked: true,
            locked_before: false,
            value_before: %{enabled: %{email: "nested-leak@example.com"}, amount_cents: 6900},
            value_after: %{enabled: %{email: "nested-leak@example.com"}, amount_cents: 9900}
          }
        })

      token = sign_in_token(admin.email, @password)
      resp = list_rule_logs(token)

      refute Jason.encode!(resp) =~ "nested-leak@example.com"
      refute Jason.encode!(resp) =~ "email"

      assert [meta] = rule_metadata_rows(resp, initiative.id)
      assert decoded(meta["valueAfterJson"]) == %{"amount_cents" => 9900}
      assert meta["valueBeforeOmitted"] == true
      assert meta["valueAfterOmitted"] == true
    end

    test "形状不完整的历史行整行落 null，且不打挂整条列表查询（#587 之前的写面形状）" do
      admin = Fixtures.platform_admin("admin-queries-aal-md-legacy")
      initiative = create_rule_initiative(admin, "gql-md-legacy")

      # origin/main（生产）上 #587 之前的 initiative_rule_metadata/2 只落这三个键，
      # 没有 value_after：若照常投影会让 non_null 的 valueAfterJson 收 nil →
      # Absinthe 非空违例 → 整条 listAdminActionLogs 失败（/admin/audit 整页 loadFailed）
      {:ok, _legacy} =
        AdminActionLog.log(%{
          actor_id: admin.id,
          action: :initiative_rule_update,
          target_type: :initiative,
          target_id: initiative.id,
          metadata: %{
            initiative_id: initiative.id,
            rule_key: "deposit",
            locked: true
          }
        })

      # 同一条查询里还要有一行完整形状——证明降级是行级的，不是整页级
      {:ok, _} =
        AdminActionLog.log(%{
          actor_id: admin.id,
          action: :initiative_rule_update,
          target_type: :initiative,
          target_id: initiative.id,
          metadata: %{
            initiative_id: initiative.id,
            rule_key: "deposit",
            locked: false,
            locked_before: true,
            value_before: %{enabled: true, amount_cents: 6900},
            value_after: %{enabled: true, amount_cents: 9900}
          }
        })

      token = sign_in_token(admin.email, @password)
      resp = list_rule_logs(token)

      # 无 GraphQL errors（非空违例会在这里现形）
      refute Map.has_key?(resp, "errors"), "列表查询不应因单行形状不全而失败: #{inspect(resp["errors"])}"

      assert %{"data" => %{"listAdminActionLogs" => logs}} = resp
      rows = Enum.filter(logs, &(&1["targetId"] == initiative.id))
      assert length(rows) == 2
      # 历史行 → 整行 null（不是「新建」，也不是半截对象）
      assert Enum.count(rows, &(&1["metadata"] == nil)) == 1
      # 完整形状行照常投影
      [full] = Enum.reject(rows, &(&1["metadata"] == nil))
      assert full["metadata"]["ruleKey"] == "deposit"

      assert decoded(full["metadata"]["valueAfterJson"]) == %{
               "enabled" => true,
               "amount_cents" => 9900
             }
    end

    test "非白名单 action 的 metadata 为 null（没有默认透传兜底）" do
      admin = Fixtures.platform_admin("admin-queries-aal-md-null")

      {:ok, workspace} =
        Workspace
        |> Ash.Changeset.for_create(:create, %{
          slug: "gql-aal-md-null-#{System.unique_integer([:positive])}",
          name: "GQL AAL null"
        })
        |> Ash.create(actor: admin)

      # 布景非空证明：raw metadata 里确实有 slug/name
      [raw] =
        AdminActionLog
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(action == :workspace_create and target_id == ^workspace.id)
        |> Ash.read!(actor: admin)

      assert raw.metadata["slug"] == workspace.slug

      token = sign_in_token(admin.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(action: "workspace_create", first: 100) {
              action targetId metadata { ruleKey locked valueAfterJson }
            }
          }
          """,
          token
        )

      assert %{"data" => %{"listAdminActionLogs" => logs}} = resp
      log = Enum.find(logs, &(&1["targetId"] == workspace.id))
      assert log, "expected workspace_create log for #{workspace.id}"
      assert log["metadata"] == nil
    end

    test "非 platform_admin 读不到该字段（负向）" do
      user = Fixtures.register_user("admin-queries-aal-md-outsider")
      token = sign_in_token(user.email, @password)

      resp =
        graphql_post(
          build_conn(),
          """
          query { listAdminActionLogs(first: 1) { metadata { ruleKey valueAfterJson } } }
          """,
          token
        )

      assert %{"errors" => [%{"message" => message} | _]} = resp
      assert message in ["forbidden", "unauthorized"]
      assert resp["data"] == nil
    end

    # 结构性防泄露的**上游**断言：响应字段集由 SDL 声明决定（选择集之外进不来），
    # 所以「读面会不会多出一个字段」只能在 SDL 层钉——未来谁给白名单投影加一个
    # 含 PII 的声明字段，这里先红，强制复审。
    test "读面声明字段集锁定为 7 个白名单字段（#607 结构性防泄露）" do
      sdl = File.read!("priv/graphql/schema.graphql")

      assert [_, body] = Regex.run(~r/type AdminActionMetadata \{(.*?)\n\}/s, sdl)

      fields =
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "\"")))
        |> Enum.map(fn line -> line |> String.split(":") |> hd() end)
        |> Enum.sort()

      assert fields ==
               ~w(locked lockedBefore ruleKey valueAfterJson valueAfterOmitted valueBeforeJson valueBeforeOmitted)
    end
  end

  # ── #607 读面测试辅助 ─────────────────────────────────────────────────────

  # 读面查询：action 过滤 + metadata 全字段选择集（单源，避免各用例写法漂移）
  defp list_rule_logs(token) do
    graphql_post(
      build_conn(),
      """
      query {
        listAdminActionLogs(action: "initiative_rule_update", first: 100) {
          action
          targetId
          metadata {
            ruleKey
            locked
            lockedBefore
            valueBeforeJson
            valueAfterJson
            valueBeforeOmitted
            valueAfterOmitted
          }
        }
      }
      """,
      token
    )
  end

  # 响应 → 指定 initiative 的 metadata 行（target_id = initiative_id，
  # 见 InitiativeRule.rule_initiative_id/2）
  defp rule_metadata_rows(resp, initiative_id) do
    assert %{"data" => %{"listAdminActionLogs" => logs}} = resp

    logs
    |> Enum.filter(&(&1["targetId"] == initiative_id))
    |> Enum.map(& &1["metadata"])
  end

  # JSON 对象字符串 → map；键序断言用 ordered_objects（默认 :maps 会丢文档序）
  defp decoded(nil), do: nil
  defp decoded(json), do: Jason.decode!(json)

  defp json_keys(json) do
    %Jason.OrderedObject{values: values} = Jason.decode!(json, objects: :ordered_objects)
    Enum.map(values, &elem(&1, 0))
  end

  # #607 布景：Initiative（draft）→ 规则走域 action，同事务落 initiative_rule_update 留痕
  defp create_rule_initiative(admin, prefix) do
    Initiative
    |> Ash.Changeset.for_create(:create, %{
      name: "审计 #{prefix}",
      slug: "#{prefix}-#{System.unique_integer([:positive])}",
      created_by: admin.id
    })
    |> Ash.create!(actor: admin)
  end

  defp create_initiative_rule(initiative, admin, key, value, locked) do
    InitiativeRule
    |> Ash.Changeset.for_create(:create, %{
      initiative_id: initiative.id,
      key: key,
      value: value,
      locked: locked
    })
    |> Ash.create(actor: admin)
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

      backdate_result =
        Ecto.Adapters.SQL.query!(
          Cgc2046.Repo,
          "UPDATE admin_action_logs SET inserted_at = $1 WHERE target_id = $2",
          [DateTime.add(now, -3 * 86_400, :second), Ecto.UUID.dump!(workspace.id)]
        )

      # #242：UPDATE 必须恰命中本测试 workspace_create 一行（收口「backdate 未命中」假设）
      assert backdate_result.num_rows == 1

      token = sign_in_token(admin.email, @password)

      # 时间窗覆盖 backdate 行 → 含本测试行
      resp =
        graphql_post(
          build_conn(),
          """
          query {
            listAdminActionLogs(
              action: "workspace_create"
              insertedAfter: "#{iso(DateTime.add(now, -3 * 86_400 - 60, :second))}"
              insertedBefore: "#{iso(DateTime.add(now, -3 * 86_400 + 60, :second))}"
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

  # 018：admin 分页 first 封顶——防任意已认证客户端全表导出
  test "AdminList.paginate first 封顶 200" do
    query = Ash.Query.new(Cgc2046.Accounts.User)
    clamped = Cgc2046.AdminList.paginate(query, 100_000, nil)

    assert clamped.limit == 200
  end
end
