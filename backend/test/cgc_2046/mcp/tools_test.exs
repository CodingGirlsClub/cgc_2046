defmodule Cgc2046.Mcp.ToolsTest do
  @moduledoc """
  MCP 工具层测试（直接调 tool execute/2，不走 HTTP）。

  覆盖计划 P1 测试先行清单：
  - workspace_id 缺失报错（D12；confirm/cancel 豁免）
  - 非成员 Forbidden
  - 确认流两段：create_invitation → needs_confirmation（不落库）→ confirm_operation → 真正落库
  - 每次调用落 ToolCallLog 审计（D9）
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame

  alias Cgc2046.Accounts.{User, Workspace}
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    CancelOperation,
    ConfirmOperation,
    CreateInvitation,
    GetWorkspaceContext
  }

  require Ash.Query

  @admin_email "mcp-tools-admin@example.com"

  defp register_user(email) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :register, %{
        email: email,
        password: "sup3r-secret-password"
      })

    user
  end

  defp platform_admin(email \\ @admin_email) do
    user = register_user(email)

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        Cgc2046.Repo,
        "UPDATE users SET is_platform_admin = true WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    Ash.get!(User, user.id, actor: user, authorize?: false, domain: Cgc2046.GlobalApi)
  end

  defp create_workspace(admin) do
    slug = "mcp-tools-ws-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Workspace
      |> Ash.Changeset.for_create(:create, %{slug: slug, name: "MCP Tools WS"})
      |> Ash.create(actor: admin)

    workspace
  end

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp tool_logs_for(user_id, tool_name) do
    ToolCallLog
    |> Ash.Query.filter(user_id == ^user_id and tool == ^tool_name)
    |> Ash.read!(authorize?: false)
  end

  describe "workspace_id 必填（D12）" do
    test "缺 workspace_id → JSON-RPC error + forbidden 审计" do
      admin = platform_admin()

      assert {:error, %Anubis.MCP.Error{reason: :execution_error, message: msg}, _frame} =
               CreateInvitation.execute(%{"target_email" => "a@b.com"}, frame_for(admin))

      assert msg =~ "workspace_id"

      [log] = tool_logs_for(admin.id, "create_invitation")
      assert log.result_status == :forbidden
    end

    test "confirm_operation / cancel_operation 不要求 workspace_id" do
      admin = platform_admin()

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => Ash.UUID.generate()}, frame_for(admin))

      # 报「不存在/非本人」而非「workspace_id 必填」，证明豁免生效
      refute msg =~ "workspace_id"

      assert {:error, %Anubis.MCP.Error{message: msg2}, _} =
               CancelOperation.execute(%{"pending_id" => Ash.UUID.generate()}, frame_for(admin))

      refute msg2 =~ "workspace_id"
    end
  end

  describe "membership 鉴权" do
    test "非成员调 get_workspace_context → Forbidden 错误 + 审计" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      outsider = register_user("mcp-tools-outsider@example.com")

      assert {:error, %Anubis.MCP.Error{reason: :execution_error, message: msg}, _} =
               GetWorkspaceContext.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(outsider)
               )

      assert msg =~ "forbidden" or msg =~ "not a member"

      [log] = tool_logs_for(outsider.id, "get_workspace_context")
      assert log.result_status == :forbidden
    end

    test "成员调 get_workspace_context → ok + ok 审计" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      assert {:reply, _, _} =
               reply =
               GetWorkspaceContext.execute(
                 %{"workspace_id" => workspace.id},
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["workspace_id"] == workspace.id
      assert is_list(payload["my_roles"])
      assert "owner" in payload["my_roles"] or "admin" in payload["my_roles"]

      [log] = tool_logs_for(admin.id, "get_workspace_context")
      assert log.result_status == :ok
      assert is_integer(log.latency_ms)
    end
  end

  describe "确认流两段（D-D3）" do
    test "create_invitation → needs_confirmation 不落库 → confirm → 真正创建 Invitation" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      # 第一段：不落 Invitation，只建 PendingOperation
      assert {:reply, _, _} =
               reply =
               CreateInvitation.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "target_email" => "invitee@example.com"
                 },
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["pending_id"]
      assert payload["summary"] =~ "invitee@example.com"
      assert payload["hint"] =~ "confirm_operation"

      # 业务库未落邀请
      assert Cgc2046.Accounts.Invitation
             |> Ash.Query.filter(workspace_id == ^workspace.id)
             |> Ash.read!(authorize?: false) == []

      [pending] = Ash.read!(PendingOperation, authorize?: false)
      assert pending.id == payload["pending_id"]
      assert pending.tool == "create_invitation"
      assert pending.user_id == admin.id

      [log] = tool_logs_for(admin.id, "create_invitation")
      assert log.result_status == :needs_confirmation
      assert log.pending_operation_id == pending.id

      # 第二段：确认 → 真正创建
      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(admin)
               )

      confirm_payload = decode_reply(confirm_reply)
      assert confirm_payload["status"] == "confirmed"
      assert confirm_payload["result"]["invitation_id"]
      assert is_binary(confirm_payload["result"]["invitation_token"])

      [invitation] =
        Cgc2046.Accounts.Invitation
        |> Ash.Query.filter(workspace_id == ^workspace.id)
        |> Ash.read!(authorize?: false)

      assert invitation.target_email == "invitee@example.com"
      assert invitation.id == confirm_payload["result"]["invitation_id"]
    end

    test "他人不可确认我的 pending" do
      admin = platform_admin()
      workspace = create_workspace(admin)
      outsider_admin = platform_admin("mcp-tools-admin2@example.com")

      {:reply, _, _} =
        reply =
        CreateInvitation.execute(
          %{"workspace_id" => workspace.id, "target_email" => "x@y.com"},
          frame_for(admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(outsider_admin))

      assert msg =~ "not found" or msg =~ "yours"

      # pending 仍未确认
      pending = Ash.get!(PendingOperation, pending_id, authorize?: false)
      assert pending.status == :pending
    end

    test "cancel_operation 取消后 confirm 被拒" do
      admin = platform_admin()
      workspace = create_workspace(admin)

      {:reply, _, _} =
        reply =
        CreateInvitation.execute(
          %{"workspace_id" => workspace.id, "target_email" => "c@d.com"},
          frame_for(admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:reply, _, _} =
               cancel_reply =
               CancelOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert decode_reply(cancel_reply)["status"] == "cancelled"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert msg =~ "cancelled" or msg =~ "not pending"

      assert Cgc2046.Accounts.Invitation
             |> Ash.Query.filter(workspace_id == ^workspace.id)
             |> Ash.read!(authorize?: false) == []
    end
  end
end
