defmodule Cgc2046Web.McpToolVisibilityTest do
  @moduledoc """
  MCP 工具可见性分层端到端测试（#1085，ADR-0021）。

  经真 endpoint 全链路（真 Bearer token：router → McpAuthPlug → anubis streamable HTTP
  transport → Server.handle_request/2 的 scope 钩子 → Wrapper 门 → 工具），断言：

  - `tools/list` 按调用者**所属最高层**恰好返回该层累计可见的**精确名单**（不是数量）；
  - 越层 `tools/call` 被 scope 层拒绝，错误文案以 `forbidden:` 开头（工具描述对 agent 的
    承诺），并补写一行 `forbidden` ToolCallLog 审计（拒绝发生在 anubis 层，到不了
    `Wrapper.run/4`，没有这条补写就丢审计，违反 ADR-0001 D6）；
  - scope 只是粗检查：通过 scope 的调用仍由 Wrapper 的 membership 门 / 工具层判定（纵深）；
  - 角色变更**下一个请求**即生效（scope 每请求重算，无需重发 token / 重开会话）。
  """
  use Cgc2046Web.ConnCase, async: false

  require Ash.Query

  alias Cgc2046.Accounts.User
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.{Token, ToolCallLog}
  alias Cgc2046.McpToolTiers, as: Tiers

  @initialize_body ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tool-visibility-test","version":"0.0.0"}}})

  # ---- endpoint helpers（真 token + 真 /mcp endpoint；与 mcp_readonly_tools_test 同款）----

  defp issue_plain_token(user) do
    {:ok, token} =
      Token
      |> Ash.Changeset.for_create(:issue, %{name: "tool visibility test"}, actor: user)
      |> Ash.create()

    token.__metadata__[:plain_token]
  end

  defp post_mcp(plain_token, body, session_id \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{plain_token}")
      |> put_req_header("content-type", "application/json")
      # accept 仅 application/json：transport 回纯 JSON（含 event-stream 会走 SSE 帧包装）
      |> put_req_header("accept", "application/json")

    conn =
      if session_id,
        do: put_req_header(conn, "mcp-session-id", session_id),
        else: conn

    post(conn, "/mcp", body)
  end

  # 连接 = 真 token + initialize 建好的会话；同一个 client 复用同一 token / 会话发后续请求
  defp connect(user) do
    plain_token = issue_plain_token(user)
    conn = post_mcp(plain_token, @initialize_body)
    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")

    %{token: plain_token, session: session_id}
  end

  defp rpc(%{token: token, session: session}, id, method, params) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    conn = post_mcp(token, body, session)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp list_names(client, id) do
    assert %{"result" => %{"tools" => tools} = result} = rpc(client, id, "tools/list", %{})
    refute Map.has_key?(result, "nextCursor"), "tools/list 不应分页（名单断言依赖单页完整列表）"

    tools |> Enum.map(& &1["name"]) |> Enum.sort()
  end

  defp call(client, id, name, arguments),
    do: rpc(client, id, "tools/call", %{"name" => name, "arguments" => arguments})

  defp logs_for(user, tool) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user.id and tool == ^tool)
    |> Ash.read!(authorize?: false)
  end

  setup do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()

    tutor = Fixtures.register_user("vis-tutor")
    Fixtures.add_member(workspace, tutor, [:tutor])

    admin = Fixtures.register_user("vis-admin")
    Fixtures.add_member(workspace, admin, [:admin])

    %{
      owner: owner,
      workspace: workspace,
      member: member,
      tutor: tutor,
      admin: admin,
      platform_admin: Fixtures.platform_admin("vis-platform"),
      orphan: Fixtures.register_user("vis-orphan")
    }
  end

  describe "tools/list 按调用者所属最高层分级" do
    test "学员 / 无角色成员 / volunteer / 无任何成员资格：只见全员可见名单（34）", ctx do
      volunteer = Fixtures.register_user("vis-volunteer")
      Fixtures.add_member(ctx.workspace, volunteer, [:volunteer])

      learner = Fixtures.register_user("vis-learner")
      Fixtures.add_member(ctx.workspace, learner, [:learner])

      for {label, user} <- [
            无角色成员: ctx.member,
            learner: learner,
            volunteer: volunteer,
            无成员资格: ctx.orphan
          ] do
        names = user |> connect() |> list_names(2)

        assert names == Tiers.visible_for(:learner), "#{label} 的可见名单与预期不符"
        assert length(names) == 34
      end
    end

    test "tutor：全员可见 + tutor 层（38）", ctx do
      names = ctx.tutor |> connect() |> list_names(2)

      assert names == Tiers.visible_for(:tutor)
      assert length(names) == 38
    end

    test "工作台 Admin 与 Owner：再加管理层（72）", ctx do
      for user <- [ctx.admin, ctx.owner] do
        names = user |> connect() |> list_names(2)

        assert names == Tiers.visible_for(:workspace_admin)
        assert length(names) == 72
        refute "admin_promote_user" in names
      end
    end

    test "平台管理员（不属于任何工作台）：全部 100，与改动前一致", ctx do
      names = ctx.platform_admin |> connect() |> list_names(2)

      assert names == Tiers.visible_for(:platform_admin)
      assert length(names) == 100
    end

    test "跨工作台并集：A 台学员、B 台 Admin → 管理层（具体哪个台仍由 Wrapper 判定）", ctx do
      %{workspace: other_workspace} = Fixtures.workspace_with_member()
      user = Fixtures.register_user("vis-union")
      Fixtures.add_member(ctx.workspace, user, [:learner])
      Fixtures.add_member(other_workspace, user, [:admin])

      assert user |> connect() |> list_names(2) == Tiers.visible_for(:workspace_admin)
    end
  end

  describe "越层 tools/call：scope 层拒绝 + forbidden 审计" do
    test "学员调平台治理工具：forbidden 前缀 + 一行 forbidden 审计，副作用未发生", ctx do
      target = Fixtures.register_user("vis-target")
      client = connect(ctx.member)

      assert %{"error" => %{"message" => "forbidden: " <> reason}} =
               call(client, 2, "admin_promote_user", %{"user_id" => target.id})

      assert reason =~ "admin_promote_user requires platform admin"
      refute Ash.get!(User, target.id, authorize?: false).is_platform_admin

      assert [log] = logs_for(ctx.member, "admin_promote_user")
      assert log.result_status == :forbidden
      assert "forbidden: " <> _ = log.error_message
    end

    test "学员调管理层工具（本人是该工作台成员）：scope 层先拒，文案是 scope 口径", ctx do
      client = connect(ctx.member)

      assert %{"error" => %{"message" => "forbidden: " <> reason}} =
               call(client, 2, "create_course", %{"workspace_id" => ctx.workspace.id})

      # 工具层 / Wrapper 的拒绝文案是 "owner or admin required to ..."；"requires ... in a workspace"
      # 只有 scope 层会产生，证明拦截发生在 Wrapper 之前
      assert reason =~ "create_course requires owner or admin role in a workspace"

      assert [log] = logs_for(ctx.member, "create_course")
      assert log.result_status == :forbidden
    end

    test "tutor 调管理层工具、Admin 调平台治理工具：同样被拒并留审计", ctx do
      tutor_client = connect(ctx.tutor)

      assert %{"error" => %{"message" => "forbidden: " <> _}} =
               call(tutor_client, 2, "create_course", %{"workspace_id" => ctx.workspace.id})

      assert [%{result_status: :forbidden}] = logs_for(ctx.tutor, "create_course")

      admin_client = connect(ctx.admin)

      assert %{"error" => %{"message" => "forbidden: " <> _}} =
               call(admin_client, 2, "admin_list_users", %{})

      assert [%{result_status: :forbidden}] = logs_for(ctx.admin, "admin_list_users")
    end

    test "缺省 arguments 的越层调用同样被拦并留审计（协议 schema 里 arguments 非必填）", ctx do
      client = connect(ctx.member)

      assert %{"error" => %{"message" => "forbidden: " <> _}} =
               rpc(client, 2, "tools/call", %{"name" => "admin_list_users"})

      assert [%{result_status: :forbidden}] = logs_for(ctx.member, "admin_list_users")
    end

    test "同层调用不受影响：学员调全员可见工具 / 平台管理员调平台治理工具均放行", ctx do
      learner_reply = ctx.member |> connect() |> call(2, "list_my_workspaces", %{})
      refute Map.has_key?(learner_reply, "error")
      assert %{"result" => %{"isError" => false, "content" => [%{"text" => _}]}} = learner_reply

      admin_reply = ctx.platform_admin |> connect() |> call(2, "admin_list_users", %{})
      refute Map.has_key?(admin_reply, "error")
      assert %{"result" => %{"isError" => false, "content" => [%{"text" => _}]}} = admin_reply
    end

    test "纵深：通过 scope 不等于有授权——Admin 调他不在的工作台，仍被 Wrapper membership 门拒绝", ctx do
      %{workspace: other_workspace} = Fixtures.workspace_with_member()
      client = connect(ctx.admin)

      assert %{"error" => %{"message" => "forbidden: not a member of workspace " <> _}} =
               call(client, 2, "list_join_requests", %{"workspace_id" => other_workspace.id})

      assert [%{result_status: :forbidden, error_message: "forbidden: not a member" <> _}] =
               logs_for(ctx.admin, "list_join_requests")
    end
  end

  describe "角色变更下一个请求立即生效（同 token、同会话）" do
    test "升级为 Admin → 管理层工具出现且可调用；降级回无角色 → 消失且被拒", ctx do
      user = Fixtures.register_user("vis-role-change")
      Fixtures.add_member(ctx.workspace, user, [])
      client = connect(user)

      assert list_names(client, 2) == Tiers.visible_for(:learner)

      Fixtures.remove_membership(ctx.workspace, user)
      Fixtures.add_member(ctx.workspace, user, [:admin])

      assert list_names(client, 3) == Tiers.visible_for(:workspace_admin)

      assert %{"result" => %{"content" => [_ | _]}} =
               call(client, 4, "list_join_requests", %{"workspace_id" => ctx.workspace.id})

      Fixtures.remove_membership(ctx.workspace, user)
      Fixtures.add_member(ctx.workspace, user, [])

      assert list_names(client, 5) == Tiers.visible_for(:learner)

      assert %{"error" => %{"message" => "forbidden: " <> reason}} =
               call(client, 6, "list_join_requests", %{"workspace_id" => ctx.workspace.id})

      assert reason =~ "list_join_requests requires owner or admin role in a workspace"
    end
  end
end
