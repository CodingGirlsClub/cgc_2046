defmodule Cgc2046.Mcp.MemberToolsTest do
  @moduledoc """
  成员管理三工具测试（#240，直接调 tool execute/2，不走 HTTP）。

  - list_join_requests：默认 pending 列表（申请人/时间/状态/预授角色提议）、
    status 过滤、非 Owner/Admin 成员拒 + 审计
  - approve_join_request：确认流两段（无 confirm 不落库）、无标签默认入座、
    管理角色不可经审批授予、已处理申请快速失败、越权拒 + 审计
  - assign_roles：确认流两段（整组替换）、最后 Owner 保护、Admin 不可碰 owner、
    越权拒 + 审计
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame

  alias Cgc2046.Accounts.{JoinRequest, WorkspaceMembership}
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}
  alias Cgc2046.Mcp.Tools.{ApproveJoinRequest, AssignRoles, ConfirmOperation, ListJoinRequests}

  require Ash.Query

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

  defp create_join_request(workspace, user) do
    JoinRequest
    |> Ash.Changeset.for_create(:create, %{workspace_id: workspace.id, user_id: user.id})
    |> Ash.create!(actor: user)
  end

  defp membership_id_for(workspace_id, user_id) do
    WorkspaceMembership
    |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> Map.fetch!(:id)
  end

  defp membership_roles(workspace_id, user_id) do
    WorkspaceMembership
    |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
    |> Ash.Query.load(:roles)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> Map.get(:roles)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp pending_status(pending_id) do
    Ash.get!(PendingOperation, pending_id, authorize?: false).status
  end

  describe "list_join_requests" do
    test "Owner 默认见 pending 列表（申请人/时间/状态/预授角色提议）" do
      admin = Fixtures.platform_admin("mm-list-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-list-applicant")
      join_request = create_join_request(workspace, applicant)

      assert {:reply, _, _} =
               reply =
               ListJoinRequests.execute(%{"workspace_id" => workspace.id}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["status"] == "pending"
      assert payload["count"] == 1

      [item] = payload["join_requests"]
      assert item["join_request_id"] == join_request.id
      assert item["applicant_user_id"] == applicant.id
      assert item["status"] == "pending"
      assert is_binary(item["submitted_at"])
      assert is_binary(item["approval_deadline"]) or is_nil(item["approval_deadline"])

      # 预授角色提议 = 可授予角色集 − 管理角色（web 审批面 GRANTABLE 语义）
      assert payload["grantable_roles"] == ["tutor", "volunteer", "learner"]

      [log] = tool_logs_for(admin.id, "list_join_requests")
      assert log.result_status == :ok
    end

    test "status 过滤：rejected 不在默认 pending 里，可显式查" do
      admin = Fixtures.platform_admin("mm-filter-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-filter-applicant")
      pending_jr = create_join_request(workspace, applicant)

      rejected_jr = create_join_request(workspace, Fixtures.register_user("mm-filter-app2"))

      {:ok, _} =
        rejected_jr
        |> Ash.Changeset.for_update(:reject, %{rejection_reason: "名额已满"})
        |> Ash.update(actor: admin, tenant: workspace.id)

      {:reply, _, _} =
        default_reply =
        ListJoinRequests.execute(%{"workspace_id" => workspace.id}, frame_for(admin))

      default = decode_reply(default_reply)
      assert default["count"] == 1
      assert hd(default["join_requests"])["join_request_id"] == pending_jr.id

      {:reply, _, _} =
        rejected_reply =
        ListJoinRequests.execute(
          %{"workspace_id" => workspace.id, "status" => "rejected"},
          frame_for(admin)
        )

      rejected = decode_reply(rejected_reply)
      assert rejected["count"] == 1
      assert hd(rejected["join_requests"])["join_request_id"] == rejected_jr.id
    end

    test "非 Owner/Admin 成员 → forbidden 落审计" do
      admin = Fixtures.platform_admin("mm-list-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mm-list-member")
      Fixtures.add_member(workspace, member, [:tutor])
      create_join_request(workspace, member)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ListJoinRequests.execute(%{"workspace_id" => workspace.id}, frame_for(member))

      assert msg =~ "forbidden"

      [log] = tool_logs_for(member.id, "list_join_requests")
      assert log.result_status == :forbidden
    end
  end

  describe "approve_join_request 确认流" do
    test "两段：needs_confirmation 不落库 → confirm 建成员并授角色" do
      admin = Fixtures.platform_admin("mm-appr-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-appr-applicant")
      join_request = create_join_request(workspace, applicant)

      # 第一段：不落业务库
      assert {:reply, _, _} =
               reply =
               ApproveJoinRequest.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "join_request_id" => join_request.id,
                   "role_names" => ["tutor"]
                 },
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ join_request.id
      assert payload["summary"] =~ applicant.id
      assert payload["summary"] =~ "tutor"

      assert Ash.get!(JoinRequest, join_request.id, authorize?: false).status == :pending

      assert [] =
               WorkspaceMembership
               |> Ash.Query.filter(workspace_id == ^workspace.id and user_id == ^applicant.id)
               |> Ash.read!(authorize?: false)

      [log] = tool_logs_for(admin.id, "approve_join_request")
      assert log.result_status == :needs_confirmation

      # 第二段：confirm → 真正落库
      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(admin)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["join_request_id"] == join_request.id
      assert confirmed["result"]["status"] == "approved"
      assert confirmed["result"]["approved_user_id"] == applicant.id
      assert confirmed["result"]["granted_roles"] == ["tutor"]

      assert Ash.get!(JoinRequest, join_request.id, authorize?: false).status == :approved
      assert membership_roles(workspace.id, applicant.id) == [:tutor]
    end

    test "缺省 role_names = 无标签入座（与 web 面默认一致）" do
      admin = Fixtures.platform_admin("mm-aptr-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-aptr-applicant")
      join_request = create_join_request(workspace, applicant)

      {:reply, _, _} =
        reply =
        ApproveJoinRequest.execute(
          %{"workspace_id" => workspace.id, "join_request_id" => join_request.id},
          frame_for(admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["granted_roles"] == []
      assert membership_roles(workspace.id, applicant.id) == []
    end

    test "管理角色不可经审批授予（owner/admin → 报错，不建 pending）" do
      admin = Fixtures.platform_admin("mm-apmg-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-apmg-applicant")
      join_request = create_join_request(workspace, applicant)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ApproveJoinRequest.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "join_request_id" => join_request.id,
                   "role_names" => ["owner"]
                 },
                 frame_for(admin)
               )

      assert msg =~ "invalid roles"
      assert [] = Ash.read!(PendingOperation, authorize?: false)
    end

    test "已处理申请快速失败（不建 pending）" do
      admin = Fixtures.platform_admin("mm-apst-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("mm-apst-applicant")
      join_request = create_join_request(workspace, applicant)

      {:ok, _} =
        join_request
        |> Ash.Changeset.for_update(:reject, %{})
        |> Ash.update(actor: admin, tenant: workspace.id)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ApproveJoinRequest.execute(
                 %{"workspace_id" => workspace.id, "join_request_id" => join_request.id},
                 frame_for(admin)
               )

      assert msg =~ "该申请已被处理"
      assert [] = Ash.read!(PendingOperation, authorize?: false)
    end

    test "非 Owner/Admin 成员 → forbidden 落审计" do
      admin = Fixtures.platform_admin("mm-apnb-owner")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mm-apnb-member")
      Fixtures.add_member(workspace, member, [:tutor])
      join_request = create_join_request(workspace, Fixtures.register_user("mm-apnb-app"))

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ApproveJoinRequest.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "join_request_id" => join_request.id,
                   "role_names" => ["tutor"]
                 },
                 frame_for(member)
               )

      assert msg =~ "forbidden"

      [log] = tool_logs_for(member.id, "approve_join_request")
      assert log.result_status == :forbidden
      assert [] = Ash.read!(PendingOperation, authorize?: false)
    end
  end

  describe "assign_roles 确认流" do
    test "两段：needs_confirmation 角色不动 → confirm 整组替换" do
      admin = Fixtures.platform_admin("mm-asr-owner")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mm-asr-member")
      Fixtures.add_member(workspace, member, [:tutor])
      membership_id = membership_id_for(workspace.id, member.id)

      # 第一段：不落库，角色仍是 [:tutor]
      assert {:reply, _, _} =
               reply =
               AssignRoles.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "membership_id" => membership_id,
                   "role_names" => ["tutor", "volunteer"]
                 },
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ membership_id
      assert payload["summary"] =~ "tutor"
      assert membership_roles(workspace.id, member.id) == [:tutor]

      [log] = tool_logs_for(admin.id, "assign_roles")
      assert log.result_status == :needs_confirmation

      # 第二段：confirm → 整组替换为请求集合
      assert {:reply, _, _} =
               confirm_reply =
               ConfirmOperation.execute(
                 %{"pending_id" => payload["pending_id"]},
                 frame_for(admin)
               )

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["membership_id"] == membership_id
      assert confirmed["result"]["user_id"] == member.id
      assert confirmed["result"]["roles"] == ["tutor", "volunteer"]

      assert membership_roles(workspace.id, member.id) == [:tutor, :volunteer]
    end

    test "最后 Owner 保护：Owner 清空自己角色 → confirm 拒绝 + pending 回滚" do
      admin = Fixtures.platform_admin("mm-aslo-owner")
      workspace = Fixtures.create_workspace(admin)
      membership_id = membership_id_for(workspace.id, admin.id)

      {:reply, _, _} =
        reply =
        AssignRoles.execute(
          %{
            "workspace_id" => workspace.id,
            "membership_id" => membership_id,
            "role_names" => []
          },
          frame_for(admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert msg =~ "工作台必须至少保留一个 Owner"
      # effect 失败回滚 pending（可重试），Owner 角色未变
      assert pending_status(pending_id) == :pending
      assert membership_roles(workspace.id, admin.id) == [:owner]
    end

    test "Admin 不可经 assign_roles 授予 owner（Rbac 守卫经 MCP 生效）" do
      admin = Fixtures.platform_admin("mm-asad-owner")
      workspace = Fixtures.create_workspace(admin)
      other_admin = Fixtures.register_user("mm-asad-admin2")
      Fixtures.add_member(workspace, other_admin, [:admin])
      target = Fixtures.register_user("mm-asad-target")
      Fixtures.add_member(workspace, target, [:tutor])
      membership_id = membership_id_for(workspace.id, target.id)

      {:reply, _, _} =
        reply =
        AssignRoles.execute(
          %{
            "workspace_id" => workspace.id,
            "membership_id" => membership_id,
            "role_names" => ["owner"]
          },
          frame_for(other_admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(other_admin))

      assert msg =~ "只有 Owner 能授予或撤销 Owner 角色"
      assert pending_status(pending_id) == :pending
      assert membership_roles(workspace.id, target.id) == [:tutor]
    end

    test "非 Owner/Admin 成员 → forbidden 落审计" do
      admin = Fixtures.platform_admin("mm-asnb-owner")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("mm-asnb-member")
      Fixtures.add_member(workspace, member, [:tutor])
      membership_id = membership_id_for(workspace.id, member.id)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AssignRoles.execute(
                 %{
                   "workspace_id" => workspace.id,
                   "membership_id" => membership_id,
                   "role_names" => ["admin"]
                 },
                 frame_for(member)
               )

      assert msg =~ "forbidden"

      [log] = tool_logs_for(member.id, "assign_roles")
      assert log.result_status == :forbidden
      assert [] = Ash.read!(PendingOperation, authorize?: false)
    end
  end
end
