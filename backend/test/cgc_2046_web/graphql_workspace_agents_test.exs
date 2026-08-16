defmodule Cgc2046Web.GraphqlWorkspaceAgentsTest do
  @moduledoc """
  plan 020 查询面验收测试（/w/[slug]/agents 工作面）。

  覆盖：

  - myWorkspaceToolCalls：workspace 成员 + 仅本人（本人可见 / 他人不可见 /
    非成员拒 / params 不在返回形状）
  - listWorkflowRuns / getWorkflowRun 扩展读取面：definition { type } +
    steps { step_key title type output_schema }（成员可读 / 跨租户拒 / 版本绑定）

  端到端解析走 ConnCase /api/graphql（完整 AshGraphQL pipeline + read policy）。
  """

  use Cgc2046Web.ConnCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.ToolCallLog

  alias Cgc2046.Workflows.{Step, WorkflowDefinition, WorkflowRun}

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

  # 造 ToolCallLog（params 内含 workspace_id，Wrapper 落库格式，D5 JSONB）
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

  defp create_definition(workspace, actor, attrs) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id, actor: actor)
      |> Ash.create(tenant: workspace.id, actor: actor)

    defn
  end

  defp publish_definition(defn, workspace, actor) do
    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: actor)
      |> Ash.update(tenant: workspace.id, actor: actor)

    published
  end

  defp create_step(workspace, actor, defn, step_key, type \\ :manual) do
    {:ok, step} =
      Step
      |> Ash.Changeset.for_create(
        :create,
        %{definition_id: defn.id, step_key: step_key, title: step_key, type: type},
        tenant: workspace.id,
        actor: actor
      )
      |> Ash.create(tenant: workspace.id, actor: actor)

    step
  end

  # learning 定义：node_def 两个 manual 步骤（带 output_schema），Step 行一一对应
  defp learning_definition do
    %{
      "steps" => [
        %{
          "id" => "module_reading",
          "type" => "manual",
          "output_schema" => %{
            "name" => "reading",
            "type" => "string",
            "label" => "阅读产出",
            "optional" => false
          }
        },
        %{"id" => "final_reflection", "type" => "manual"}
      ]
    }
  end

  defp seeded_learning_run do
    admin = Fixtures.platform_admin("agents-wf")
    workspace = Fixtures.create_workspace(admin)

    defn =
      create_definition(workspace, admin, %{
        name: "学习 workflow",
        type: :learning,
        node_def: learning_definition()
      })

    create_step(workspace, admin, defn, "module_reading")
    create_step(workspace, admin, defn, "final_reflection")
    published = publish_definition(defn, workspace, admin)

    # 学习 run 协议路径：:start（pending → running，不经 Engine）
    {:ok, run, :created} =
      WorkflowRun.find_or_create_and_start(workspace.id, published, %{}, start_action: :start)

    {admin, workspace, published, run}
  end

  describe "myWorkspaceToolCalls（plan 020 U2.1）" do
    test "本人可见：只返回本人在该工作台的调用，返回形状不含 params" do
      {_admin, workspace, _defn, _run} = seeded_learning_run()
      member = Fixtures.add_member(workspace, Fixtures.register_user("agents-member"))
      member = Cgc2046.Accounts.User |> Ash.get!(member.user_id, authorize?: false)

      ws_id = workspace.id
      other = Fixtures.register_user("agents-other")

      create_tool_call_log(%{
        user_id: member.id,
        tool: "get_workspace_context",
        params: %{"workspace_id" => ws_id, "tool" => "get_workspace_context"},
        result_status: :ok,
        latency_ms: 12
      })

      create_tool_call_log(%{
        user_id: member.id,
        tool: "list_members",
        params: %{"workspace_id" => ws_id},
        result_status: :error,
        error_message: "boom",
        latency_ms: 7
      })

      # 他人调用（同工作台）不应出现在本人流中
      create_tool_call_log(%{
        user_id: other.id,
        tool: "list_members",
        params: %{"workspace_id" => ws_id},
        result_status: :ok
      })

      token = sign_in_token(member.email, Fixtures.password())

      query = """
      query {
        myWorkspaceToolCalls(workspaceId: "#{ws_id}") {
          id tool status latencyMs insertedAt errorMessage
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"data" => %{"myWorkspaceToolCalls" => calls}} = res
      assert length(calls) == 2

      # 时间线排序：新→旧（list_members 后落库，应在第一）
      assert ["list_members", "get_workspace_context"] = Enum.map(calls, & &1["tool"])

      # 返回形状 = 摘要字段集合，绝不含 params
      keys = calls |> hd() |> Map.keys() |> MapSet.new()
      refute MapSet.member?(keys, "params")

      assert %{"status" => "error", "errorMessage" => "boom", "latencyMs" => 7} =
               Enum.find(calls, &(&1["tool"] == "list_members"))
    end

    test "他人不可见：同工作台他人调用不返回（空列表）" do
      {_admin, workspace, _defn, _run} = seeded_learning_run()
      member = Fixtures.add_member(workspace, Fixtures.register_user("agents-member2"))
      member = Cgc2046.Accounts.User |> Ash.get!(member.user_id, authorize?: false)
      other = Fixtures.register_user("agents-other2")

      # 只有他人调用
      create_tool_call_log(%{
        user_id: other.id,
        tool: "list_members",
        params: %{"workspace_id" => workspace.id},
        result_status: :ok
      })

      token = sign_in_token(member.email, Fixtures.password())

      query = """
      query {
        myWorkspaceToolCalls(workspaceId: "#{workspace.id}") {
          id tool
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"data" => %{"myWorkspaceToolCalls" => calls}} = res
      assert calls == []
    end

    test "非成员拒：非成员查询 forbidden" do
      {_admin, workspace, _defn, _run} = seeded_learning_run()
      outsider = Fixtures.register_user("agents-outsider")
      token = sign_in_token(outsider.email, Fixtures.password())

      query = """
      query {
        myWorkspaceToolCalls(workspaceId: "#{workspace.id}") {
          id tool
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{"errors" => errors} = res
      assert Enum.any?(errors, &(&1["message"] == "forbidden"))
    end
  end

  describe "steps 读取面（plan 020 U3：definition{type} + steps）" do
    test "成员可读：definition.type + steps（step_key/title/type/output_schema）" do
      {admin, _workspace, _defn, run} = seeded_learning_run()
      token = sign_in_token(admin.email, Fixtures.password())

      query = """
      query {
        getWorkflowRun(id: "#{run.id}") {
          id
          definition { type version }
          steps
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{
               "data" => %{
                 "getWorkflowRun" => %{
                   "id" => id,
                   "definition" => %{"type" => "learning", "version" => 1},
                   "steps" => steps
                 }
               }
             } = res

      assert id == run.id
      assert is_list(steps) and length(steps) == 2

      # steps 是 JsonString 数组：解析后为 step_key/title/type/output_schema
      parsed = Enum.map(steps, &Jason.decode!/1)

      assert %{
               "step_key" => "module_reading",
               "title" => "module_reading",
               "type" => "manual",
               "output_schema" => %{
                 "name" => "reading",
                 "type" => "string",
                 "label" => "阅读产出",
                 "optional" => false
               }
             } = Enum.find(parsed, &(&1["step_key"] == "module_reading"))

      # 旧数据兼容：无 output_schema 的步骤 → null
      assert %{"step_key" => "final_reflection", "output_schema" => nil} =
               Enum.find(parsed, &(&1["step_key"] == "final_reflection"))
    end

    test "跨租户拒：非成员读不到 run（列表空 + getWorkflowRun null）" do
      {_admin, workspace, _defn, run} = seeded_learning_run()
      outsider = Fixtures.register_user("agents-outsider2")
      token = sign_in_token(outsider.email, Fixtures.password())

      list_query = """
      query {
        listWorkflowRuns(filter: {workspaceId: {eq: "#{workspace.id}"}}) {
          count
          results { id definition { type } steps }
        }
      }
      """

      res = graphql_post(build_conn(), list_query, token)

      assert %{
               "data" => %{
                 "listWorkflowRuns" => %{"count" => 0, "results" => []}
               }
             } = res

      get_query = """
      query {
        getWorkflowRun(id: "#{run.id}") {
          id definition { type } steps
        }
      }
      """

      res2 = graphql_post(build_conn(), get_query, token)
      assert %{"data" => %{"getWorkflowRun" => nil}} = res2
    end

    test "版本绑定：run 按创建时绑定版本读 steps，不读最新定义" do
      {admin, workspace, defn_v1, run} = seeded_learning_run()

      # new_version → draft v2（复制 v1 步骤），追加 extra_step 后发布
      {:ok, draft_v2} =
        WorkflowDefinition
        |> Ash.Changeset.for_create(
          :new_version,
          %{source_definition_id: defn_v1.id},
          tenant: workspace.id,
          actor: admin
        )
        |> Ash.create(tenant: workspace.id, actor: admin)

      create_step(workspace, admin, draft_v2, "extra_step")
      published_v2 = publish_definition(draft_v2, workspace, admin)

      assert published_v2.version == 2

      token = sign_in_token(admin.email, Fixtures.password())

      query = """
      query {
        getWorkflowRun(id: "#{run.id}") {
          definition { type version }
          steps
        }
      }
      """

      res = graphql_post(build_conn(), query, token)

      assert %{
               "data" => %{
                 "getWorkflowRun" => %{
                   "definition" => %{"type" => "learning", "version" => 1},
                   "steps" => steps
                 }
               }
             } = res

      # v1 绑定：只有 module_reading + final_reflection，无 v2 新增的 extra_step
      parsed = Enum.map(steps, &Jason.decode!/1)
      step_keys = Enum.map(parsed, & &1["step_key"]) |> Enum.sort()
      assert step_keys == ["final_reflection", "module_reading"]
    end
  end
end
