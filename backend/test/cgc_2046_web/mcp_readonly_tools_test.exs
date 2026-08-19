defmodule Cgc2046Web.McpReadonlyToolsTest do
  @moduledoc """
  MCP 只读三工具执行测试（#214）：get_workflow / get_step_output / list_members。

  经真 endpoint 全链路（真 Bearer token：router → McpAuthPlug → anubis
  streamable HTTP transport → Wrapper 门 → 工具执行），initialize 建会话后
  tools/call：

  - 成员正常调用返回正确数据（结构 + 内容断言，非仅「不报错」）
  - 非成员拒绝（Wrapper membership 门，fail-closed）
  - list_members：非成员**平台管理员**同样拒——钉住「MCP membership 门不含
    platform_admin 豁免」双面契约（policy/GraphQL 面 admin 跨租户治理读放行，
    MCP 面不放行，见 `Cgc2046.Mcp.Wrapper` moduledoc）
  """
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Workflows.{WorkflowDefinition, WorkflowRun}
  alias Cgc2046.Mcp.Token

  # async: false —— 工具执行在 anubis session 的 Task 进程中跑，需要 sandbox
  # shared 模式（ConnCase setup 以 shared: not tags[:async] 开 checkout），
  # async: true 会 OwnershipError。
  use Cgc2046Web.ConnCase, async: false

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"readonly-tools-test","version":"0.0.0"}}})

  @facts %{
    "outline_design" => %{"outline" => ["引言", "正文"]},
    "content_review" => %{"approved" => true}
  }

  # ---- endpoint helpers（真 token + 真 /mcp endpoint）----

  defp issue_plain_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "readonly tools test"}, actor: user)
      |> Ash.create()

    token.__metadata__[:plain_token]
  end

  defp post_mcp(plain_token, body, session_id \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain_token}")
      |> put_req_header("content-type", "application/json")
      # accept 仅 application/json：不含 text/event-stream → transport 回纯 JSON
      # （含 event-stream 会走 SSE 帧 "event: message\ndata: ..." 包装）
      |> put_req_header("accept", "application/json")

    conn =
      if session_id,
        do: put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    post(conn, "/mcp", body)
  end

  defp open_session(plain_token) do
    conn = post_mcp(plain_token, @initialize_body)

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  defp call_tool(plain_token, session_id, id, name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    conn = post_mcp(plain_token, body, session_id)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp result_payload(%{"result" => %{"content" => [%{"text" => text}]}}),
    do: Jason.decode!(text)

  # ---- 业务 fixture ----

  defp publish_definition(workspace, owner) do
    {:ok, defn} =
      WorkflowDefinition
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "教研 workflow",
          type: :research,
          input_schema: %{"topic" => "string"},
          node_def: %{steps: ["outline_design", "content_review"]},
          approval_timeout: 604_800
        },
        tenant: workspace.id,
        actor: owner
      )
      |> Ash.create(tenant: workspace.id, actor: owner)

    {:ok, published} =
      defn
      |> Ash.Changeset.for_update(:publish, %{}, actor: owner)
      |> Ash.update(tenant: workspace.id, actor: owner)

    published
  end

  defp succeeded_run(workspace, owner, defn, facts) do
    {:ok, run} =
      WorkflowRun
      |> Ash.Changeset.for_create(
        :create,
        %{
          definition_id: defn.id,
          definition_version: defn.version,
          input_snapshot: %{"topic" => "t1"}
        },
        tenant: workspace.id,
        actor: owner
      )
      |> Ash.create(tenant: workspace.id, actor: owner)

    {:ok, run} =
      run
      |> Ash.Changeset.for_update(:start, %{}, actor: owner)
      |> Ash.update(tenant: workspace.id, actor: owner)

    {:ok, run} =
      run
      |> Ash.Changeset.for_update(:complete, %{facts: facts}, actor: owner)
      |> Ash.update(tenant: workspace.id, actor: owner)

    run
  end

  defp setup_workspace_with_run do
    owner = Fixtures.platform_admin("mcp-ro-owner")
    workspace = Fixtures.create_workspace(owner)
    tutor = Fixtures.register_user("mcp-ro-tutor")
    Fixtures.add_member(workspace, tutor, [:tutor])
    defn = publish_definition(workspace, owner)
    run = succeeded_run(workspace, owner, defn, @facts)

    %{owner: owner, workspace: workspace, tutor: tutor, defn: defn, run: run}
  end

  describe "get_workflow" do
    test "成员调用返回 run 状态与 facts keys" do
      ctx = setup_workspace_with_run()
      plain = issue_plain_token(ctx.owner)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "get_workflow", %{
          "workspace_id" => ctx.workspace.id,
          "run_id" => ctx.run.id
        })

      refute Map.has_key?(reply, "error")

      assert result_payload(reply) == %{
               "run_id" => ctx.run.id,
               "status" => "succeeded",
               "definition_id" => ctx.defn.id,
               "definition_version" => ctx.defn.version,
               "step_keys_with_facts" => ["content_review", "outline_design"],
               "started_at" => DateTime.to_iso8601(ctx.run.started_at),
               "finished_at" => DateTime.to_iso8601(ctx.run.finished_at)
             }
    end

    test "非成员拒（Wrapper membership 门）" do
      ctx = setup_workspace_with_run()
      outsider = Fixtures.register_user("mcp-ro-outsider-gw")
      plain = issue_plain_token(outsider)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "get_workflow", %{
          "workspace_id" => ctx.workspace.id,
          "run_id" => ctx.run.id
        })

      assert %{"error" => %{"message" => message}} = reply
      assert message =~ "forbidden: not a member of workspace"
    end
  end

  describe "get_step_output" do
    test "成员调用返回该 step 的产出 map" do
      ctx = setup_workspace_with_run()
      plain = issue_plain_token(ctx.owner)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "get_step_output", %{
          "workspace_id" => ctx.workspace.id,
          "run_id" => ctx.run.id,
          "step_key" => "outline_design"
        })

      assert result_payload(reply) == %{
               "run_id" => ctx.run.id,
               "step_key" => "outline_design",
               "output" => %{"outline" => ["引言", "正文"]}
             }
    end

    test "成员调不存在的 step_key → 明确错误" do
      ctx = setup_workspace_with_run()
      plain = issue_plain_token(ctx.owner)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "get_step_output", %{
          "workspace_id" => ctx.workspace.id,
          "run_id" => ctx.run.id,
          "step_key" => "no_such_step"
        })

      assert %{"error" => %{"message" => message}} = reply
      assert message =~ "no output for step no_such_step"
    end

    test "非成员拒" do
      ctx = setup_workspace_with_run()
      outsider = Fixtures.register_user("mcp-ro-outsider-gso")
      plain = issue_plain_token(outsider)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "get_step_output", %{
          "workspace_id" => ctx.workspace.id,
          "run_id" => ctx.run.id,
          "step_key" => "outline_design"
        })

      assert %{"error" => %{"message" => message}} = reply
      assert message =~ "forbidden: not a member of workspace"
    end
  end

  describe "list_members" do
    test "Owner 调用返回全部成员与角色" do
      ctx = setup_workspace_with_run()
      plain = issue_plain_token(ctx.owner)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "list_members", %{
          "workspace_id" => ctx.workspace.id
        })

      payload = result_payload(reply)
      assert payload["workspace_id"] == ctx.workspace.id
      members = payload["members"]

      by_user = Map.new(members, &{&1["user_id"], &1})

      assert MapSet.new(Map.keys(by_user)) == MapSet.new([ctx.owner.id, ctx.tutor.id])
      assert by_user[ctx.owner.id]["roles"] == ["owner"]
      assert by_user[ctx.tutor.id]["roles"] == ["tutor"]
      assert Enum.all?(members, &is_binary(&1["membership_id"]))
    end

    test "非成员拒" do
      ctx = setup_workspace_with_run()
      outsider = Fixtures.register_user("mcp-ro-outsider-lm")
      plain = issue_plain_token(outsider)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "list_members", %{
          "workspace_id" => ctx.workspace.id
        })

      assert %{"error" => %{"message" => message}} = reply
      assert message =~ "forbidden: not a member of workspace"
    end

    test "非成员平台管理员也拒——MCP 门不含 platform_admin 豁免（双面契约）" do
      ctx = setup_workspace_with_run()
      # 真平台管理员（is_platform_admin），但未加入目标 workspace：
      # 资源 read policy 面本会放行（WorkspaceMembership read policy 有
      # PlatformAdmin bypass），MCP Wrapper membership 门先拦——两面刻意不同答。
      pa = Fixtures.platform_admin("mcp-ro-pa")
      plain = issue_plain_token(pa)
      session = open_session(plain)

      reply =
        call_tool(plain, session, 2, "list_members", %{
          "workspace_id" => ctx.workspace.id
        })

      assert %{"error" => %{"message" => message}} = reply
      assert message =~ "forbidden: not a member of workspace"
    end
  end
end
