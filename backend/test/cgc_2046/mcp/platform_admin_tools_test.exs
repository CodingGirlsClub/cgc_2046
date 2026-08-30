defmodule Cgc2046.Mcp.PlatformAdminToolsTest do
  @moduledoc """
  平台治理十工具测试（role-agent-journeys-v2 S2，直接调 tool execute/2，不走 HTTP）。

  - 门控：非平台管理员（含 workspace owner）十工具一律 forbidden + 审计
  - 读四件：admin 见用户/工作台/申请；admin_list_audit_logs 三源只投影操作
    元数据（断言无 params/payload/metadata 键，§B#21 结构性免疫）
  - 写六件（确认流两段）：approve/reject 申请、create_workspace 双 Owner 路径、
    pending-owner 重指派、promote/demote（≥1 admin 不变量错误原文透传；
    确认窗口内角色被撤 → confirm 被域 policy 拒 + pending 回滚可重试）
  - cancel_operation 无副作用；他人 pending 不可确认（新分派子句同受归属校验保护）

  async: false + setup 清 admin 标记：≥1 admin 不变量依赖全局计数
  （同 demote_platform_admin_test 的纪律）。
  """
  use Cgc2046.DataCase, async: false

  alias Anubis.Server.Frame

  alias Cgc2046.Accounts.{
    AdminActionLog,
    MembershipContext,
    User,
    Workspace,
    WorkspaceApplication
  }

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.{PendingOperation, ToolCallLog}

  alias Cgc2046.Mcp.Tools.{
    AdminApproveWorkspaceApplication,
    AdminCreateWorkspace,
    AdminDemoteUser,
    AdminListAuditLogs,
    AdminListUsers,
    AdminListWorkspaceApplications,
    AdminListWorkspaces,
    AdminPromoteUser,
    AdminReassignWorkspaceOwner,
    AdminRejectWorkspaceApplication,
    CancelOperation,
    ConfirmOperation
  }

  require Ash.Query

  setup do
    Fixtures.reset_platform_admins()
    :ok
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

  defp create_workspace_application(user, attrs \\ %{}) do
    changes =
      Map.merge(
        %{
          applicant_id: user.id,
          name: "App WS",
          slug: "pa-app-#{System.unique_integer([:positive])}",
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

  defp membership_roles(workspace_id, user_id) do
    Cgc2046.Accounts.WorkspaceMembership
    |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
    |> Ash.Query.load(:roles)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> case do
      nil -> []
      membership -> membership.roles |> Enum.map(& &1.name) |> Enum.sort()
    end
  end

  defp workspace_by_slug(slug) do
    Workspace
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # 共享沙箱（async: false → shared mode）下并发 async 测试的未提交行对本测试
  # 可见：全局表断言一律收窄到本测试独占的 target_id / user_id，不断言全表形状。
  defp admin_action_logs(action, target_id) do
    AdminActionLog
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read!(authorize?: false)
  end

  defp pendings_of(user_id) do
    PendingOperation
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  defp pending_status(pending_id) do
    Ash.get!(PendingOperation, pending_id, authorize?: false).status
  end

  describe "门控：非平台管理员一律 forbidden" do
    test "workspace owner（非平台管理员）调十工具全部 forbidden 落审计" do
      %{owner: owner, workspace: workspace} = Fixtures.workspace_with_member()

      tools = [
        {AdminListUsers, %{}},
        {AdminListWorkspaces, %{}},
        {AdminListWorkspaceApplications, %{}},
        {AdminListAuditLogs, %{"source" => "tool_calls"}},
        {AdminApproveWorkspaceApplication, %{"application_id" => Ecto.UUID.generate()}},
        {AdminRejectWorkspaceApplication, %{"application_id" => Ecto.UUID.generate()}},
        {AdminCreateWorkspace, %{"name" => "X", "owner_email" => "x@example.com"}},
        {AdminReassignWorkspaceOwner,
         %{"workspace_id" => workspace.id, "new_owner_email" => "x@example.com"}},
        {AdminPromoteUser, %{"user_id" => owner.id}},
        {AdminDemoteUser, %{"user_id" => owner.id}}
      ]

      for {tool, params} <- tools do
        assert {:error, %Anubis.MCP.Error{message: msg}, _} =
                 tool.execute(params, frame_for(owner)),
               "expected #{inspect(tool)} to forbid non-platform-admin"

        assert msg =~ "forbidden: platform admin required"
      end

      logs =
        ToolCallLog
        |> Ash.Query.filter(user_id == ^owner.id)
        |> Ash.read!(authorize?: false)

      assert length(logs) == 10
      assert Enum.all?(logs, &(&1.result_status == :forbidden))
      assert Enum.all?(logs, &String.starts_with?(&1.tool, "admin_"))
      # 门控在业务 fun 之前：不落任何 pending
      assert [] = pendings_of(owner.id)
    end
  end

  describe "读工具" do
    test "admin_list_users：search 过滤 + 紧凑字段" do
      admin = Fixtures.platform_admin("pa-users-admin")
      user = Fixtures.register_user("pa-users-bob")

      assert {:reply, _, _} =
               reply = AdminListUsers.execute(%{"search" => "pa-users-bob"}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["count"] == 1

      [row] = payload["users"]
      assert row["id"] == user.id
      assert row["email"] == to_string(user.email)
      assert row["is_platform_admin"] == false
      assert Map.has_key?(row, "display_name")
      assert Map.has_key?(row, "inserted_at")

      # 无 search 改为公共前缀 search（共享沙箱下并发测试的用户会同列，不断言全量）
      {:reply, _, _} =
        all_reply = AdminListUsers.execute(%{"search" => "pa-users"}, frame_for(admin))

      all = decode_reply(all_reply)
      ids = Enum.map(all["users"], & &1["id"])
      assert admin.id in ids
      assert user.id in ids
    end

    test "admin_list_workspaces：search 过滤 + member_count" do
      admin = Fixtures.platform_admin("pa-ws-admin")
      workspace = Fixtures.create_workspace(admin, %{slug: "pa-ws-alpha", name: "Alpha WS"})

      assert {:reply, _, _} =
               reply =
               AdminListWorkspaces.execute(%{"search" => "pa-ws-alpha"}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["count"] == 1

      [row] = payload["workspaces"]
      assert row["id"] == workspace.id
      assert row["slug"] == "pa-ws-alpha"
      assert row["join_policy"] == "request"
      assert row["member_count"] == 1
      assert Map.has_key?(row, "inserted_at")
    end

    test "admin_list_workspace_applications：默认 pending + status 过滤 + 申请人概要" do
      admin = Fixtures.platform_admin("pa-apps-admin")
      applicant = Fixtures.register_user("pa-apps-applicant")
      pending_app = create_workspace_application(applicant)
      rejected_app = create_workspace_application(applicant)

      {:ok, _} =
        rejected_app
        |> Ash.Changeset.for_update(:reject, %{rejection_reason: "重复申请"})
        |> Ash.update(actor: admin)

      assert {:reply, _, _} =
               reply = AdminListWorkspaceApplications.execute(%{}, frame_for(admin))

      # 共享沙箱下并发测试的申请同列可见：断言成员关系而非精确计数
      payload = decode_reply(reply)
      assert payload["status"] == "pending"

      pending_ids = Enum.map(payload["applications"], & &1["application_id"])
      assert pending_app.id in pending_ids
      refute rejected_app.id in pending_ids

      row = Enum.find(payload["applications"], &(&1["application_id"] == pending_app.id))
      assert row["status"] == "pending"
      assert row["applicant"]["id"] == applicant.id
      assert row["applicant"]["email"] == to_string(applicant.email)
      assert Map.has_key?(row, "approval_deadline")

      {:reply, _, _} =
        rejected_reply =
        AdminListWorkspaceApplications.execute(%{"status" => "rejected"}, frame_for(admin))

      rejected = decode_reply(rejected_reply)
      rejected_ids = Enum.map(rejected["applications"], & &1["application_id"])
      assert rejected_app.id in rejected_ids
      refute pending_app.id in rejected_ids
    end

    test "admin_list_audit_logs：三源只投影操作元数据，无 params/payload/metadata 键" do
      admin = Fixtures.platform_admin("pa-audit-admin")
      target = Fixtures.register_user("pa-audit-target")

      # 造三源数据：一次读工具调用 + 一次 promote 确认流
      {:reply, _, _} = AdminListUsers.execute(%{}, frame_for(admin))

      {:reply, _, _} =
        promote_reply =
        AdminPromoteUser.execute(%{"user_id" => target.id}, frame_for(admin))

      %{"pending_id" => pending_id} = decode_reply(promote_reply)
      {:reply, _, _} = ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      # tool_calls
      {:reply, _, _} =
        tc_reply = AdminListAuditLogs.execute(%{"source" => "tool_calls"}, frame_for(admin))

      tc = decode_reply(tc_reply)
      assert tc["count"] >= 1

      assert Enum.any?(
               tc["logs"],
               &(&1["tool"] == "admin_list_users" and &1["result_status"] == "ok")
             )

      for row <- tc["logs"] do
        assert Map.has_key?(row, "user_id")
        assert Map.has_key?(row, "tool")
        assert Map.has_key?(row, "result_status")
        assert Map.has_key?(row, "latency_ms")
        assert Map.has_key?(row, "inserted_at")
        refute Map.has_key?(row, "params")
        refute Map.has_key?(row, "payload")
      end

      # pending_operations（并发测试的 pending 同列可见：按本测试的 pending_id 取行）
      {:reply, _, _} =
        po_reply =
        AdminListAuditLogs.execute(%{"source" => "pending_operations"}, frame_for(admin))

      po = decode_reply(po_reply)
      assert row = Enum.find(po["logs"], &(&1["id"] == pending_id))
      assert row["tool"] == "admin_promote_user"
      assert row["status"] == "confirmed"
      assert Map.has_key?(row, "expires_at")

      for row <- po["logs"] do
        refute Map.has_key?(row, "params")
        refute Map.has_key?(row, "summary")
      end

      # admin_actions（并发测试的留痕同列可见：按本测试的 target_id 取行）
      {:reply, _, _} =
        aa_reply = AdminListAuditLogs.execute(%{"source" => "admin_actions"}, frame_for(admin))

      aa = decode_reply(aa_reply)

      assert row =
               Enum.find(
                 aa["logs"],
                 &(&1["target_id"] == target.id and &1["action"] == "admin_promote")
               )

      assert row["actor_id"] == admin.id
      assert row["target_type"] == "user"
      assert row["result"] == "success"

      for row <- aa["logs"] do
        refute Map.has_key?(row, "metadata")
        refute Map.has_key?(row, "params")
      end
    end

    test "admin_list_audit_logs：非法 source → error" do
      admin = Fixtures.platform_admin("pa-audit-bad")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminListAuditLogs.execute(%{"source" => "bogus"}, frame_for(admin))

      assert msg =~ "invalid source"
    end
  end

  describe "admin_approve_workspace_application 确认流" do
    test "两段：needs_confirmation 无副作用 → confirm 批申请 + 建 workspace + 申请人入座 Owner" do
      admin = Fixtures.platform_admin("pa-appr-admin")
      applicant = Fixtures.register_user("pa-appr-applicant")
      application = create_workspace_application(applicant, %{name: "治理审批台"})

      # 第一段：不落业务库
      assert {:reply, _, _} =
               reply =
               AdminApproveWorkspaceApplication.execute(
                 %{"application_id" => application.id},
                 frame_for(admin)
               )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ application.id
      assert payload["summary"] =~ application.name

      assert Ash.get!(WorkspaceApplication, application.id, authorize?: false).status == :pending
      assert workspace_by_slug(application.slug) == nil

      [log] = tool_logs_for(admin.id, "admin_approve_workspace_application")
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
      assert confirmed["result"]["application_id"] == application.id
      assert confirmed["result"]["status"] == "approved"

      assert Ash.get!(WorkspaceApplication, application.id, authorize?: false).status == :approved

      workspace = workspace_by_slug(application.slug)
      assert workspace.name == "治理审批台"
      assert membership_roles(workspace.id, applicant.id) == [:owner]

      [action_log] = admin_action_logs(:application_approve, application.id)
      assert action_log.actor_id == admin.id
    end

    test "已处理申请快速失败（不建 pending）" do
      admin = Fixtures.platform_admin("pa-apst-admin")
      applicant = Fixtures.register_user("pa-apst-applicant")
      application = create_workspace_application(applicant)

      {:ok, _} =
        application
        |> Ash.Changeset.for_update(:reject, %{})
        |> Ash.update(actor: admin)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminApproveWorkspaceApplication.execute(
                 %{"application_id" => application.id},
                 frame_for(admin)
               )

      assert msg =~ "该申请已被处理"
      assert [] = pendings_of(admin.id)
    end
  end

  describe "admin_reject_workspace_application 确认流" do
    test "两段：confirm 后落拒绝原因 + 治理留痕" do
      admin = Fixtures.platform_admin("pa-rej-admin")
      applicant = Fixtures.register_user("pa-rej-applicant")
      application = create_workspace_application(applicant)

      {:reply, _, _} =
        reply =
        AdminRejectWorkspaceApplication.execute(
          %{"application_id" => application.id, "rejection_reason" => "名称不合规"},
          frame_for(admin)
        )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "名称不合规"

      assert Ash.get!(WorkspaceApplication, application.id, authorize?: false).status == :pending

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["status"] == "rejected"
      assert confirmed["result"]["rejection_reason"] == "名称不合规"

      reloaded = Ash.get!(WorkspaceApplication, application.id, authorize?: false)
      assert reloaded.status == :rejected
      assert reloaded.rejection_reason == "名称不合规"
      assert reloaded.rejected_by == admin.id

      [action_log] = admin_action_logs(:application_reject, application.id)
      assert action_log.actor_id == admin.id
    end
  end

  describe "admin_create_workspace 确认流" do
    test "owner_user_id 路径：confirm 建 workspace + 指定用户入座 Owner" do
      admin = Fixtures.platform_admin("pa-cw-admin")
      owner = Fixtures.register_user("pa-cw-owner")

      # 第一段：不落业务库
      {:reply, _, _} =
        reply =
        AdminCreateWorkspace.execute(
          %{"name" => "直建工作台", "slug" => "pa-cw-direct", "owner_user_id" => owner.id},
          frame_for(admin)
        )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ "pa-cw-direct"
      assert payload["summary"] =~ to_string(owner.email)
      assert workspace_by_slug("pa-cw-direct") == nil

      # 第二段
      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["status"] == "confirmed"
      assert confirmed["result"]["slug"] == "pa-cw-direct"
      assert confirmed["result"]["owner_user_id"] == owner.id
      assert is_nil(confirmed["result"]["owner_invitation_token"])

      workspace = workspace_by_slug("pa-cw-direct")
      assert workspace.name == "直建工作台"
      assert membership_roles(workspace.id, owner.id) == [:owner]

      [action_log] = admin_action_logs(:workspace_create, workspace.id)
      assert action_log.actor_id == admin.id
    end

    test "owner_email 路径：confirm 建 pending-owner workspace + token 一次性返回" do
      admin = Fixtures.platform_admin("pa-cwe-admin")

      {:reply, _, _} =
        reply =
        AdminCreateWorkspace.execute(
          %{"name" => "Beacon Lab", "owner_email" => "new-owner@example.com"},
          frame_for(admin)
        )

      payload = decode_reply(reply)
      # slug 缺省派生自 ASCII 名称
      assert payload["summary"] =~ "beacon-lab"

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["slug"] == "beacon-lab"
      assert confirmed["result"]["owner_email"] == "new-owner@example.com"
      assert is_binary(confirmed["result"]["owner_invitation_token"])

      workspace = workspace_by_slug("beacon-lab")
      assert MembershipContext.ownerless?(workspace.id)
    end

    test "owner 指定二选一：都不给 / 都给 → error 不建 pending" do
      admin = Fixtures.platform_admin("pa-cwv-admin")
      owner = Fixtures.register_user("pa-cwv-owner")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminCreateWorkspace.execute(%{"name" => "X"}, frame_for(admin))

      assert msg =~ "必须提供其一"

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminCreateWorkspace.execute(
                 %{
                   "name" => "X",
                   "owner_user_id" => owner.id,
                   "owner_email" => "x@example.com"
                 },
                 frame_for(admin)
               )

      assert msg =~ "只能提供一个"
      assert [] = pendings_of(admin.id)
    end
  end

  describe "admin_reassign_workspace_owner 确认流" do
    test "pending-owner 期间改指现有用户：confirm 后新 Owner 入座 + 留痕" do
      admin = Fixtures.platform_admin("pa-ro-admin")

      # 布置 pending-owner 工作台（owner_email 路径，邀请未接受）
      workspace =
        Workspace
        |> Ash.Changeset.for_create(
          :create,
          %{
            slug: "pa-ro-#{System.unique_integer([:positive])}",
            name: "Pending Owner WS",
            owner_email: "pending-owner@example.com"
          }
        )
        |> Ash.create!(actor: admin)

      assert MembershipContext.ownerless?(workspace.id)
      new_owner = Fixtures.register_user("pa-ro-new-owner")

      {:reply, _, _} =
        reply =
        AdminReassignWorkspaceOwner.execute(
          %{"workspace_id" => workspace.id, "new_owner_user_id" => new_owner.id},
          frame_for(admin)
        )

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ workspace.id
      # 第一段无副作用：仍 ownerless
      assert MembershipContext.ownerless?(workspace.id)

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["workspace_id"] == workspace.id
      assert confirmed["result"]["new_owner_user_id"] == new_owner.id

      assert membership_roles(workspace.id, new_owner.id) == [:owner]
      refute MembershipContext.ownerless?(workspace.id)

      [action_log] = admin_action_logs(:owner_reassign, workspace.id)
      assert action_log.actor_id == admin.id
    end

    test "已有 Owner 的工作台第一段即失败（不建 pending）" do
      admin = Fixtures.platform_admin("pa-roh-admin")
      workspace = Fixtures.create_workspace(admin)
      new_owner = Fixtures.register_user("pa-roh-new-owner")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminReassignWorkspaceOwner.execute(
                 %{"workspace_id" => workspace.id, "new_owner_user_id" => new_owner.id},
                 frame_for(admin)
               )

      assert msg =~ "重指派仅适用于 pending-owner 期间"
      assert [] = pendings_of(admin.id)
    end
  end

  describe "admin_promote_user / admin_demote_user 确认流" do
    test "promote 两段：confirm 前非管理员 → confirm 后是 + 治理留痕" do
      admin = Fixtures.platform_admin("pa-pm-admin")
      target = Fixtures.register_user("pa-pm-target")

      {:reply, _, _} =
        reply = AdminPromoteUser.execute(%{"user_id" => target.id}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["status"] == "needs_confirmation"
      assert payload["summary"] =~ to_string(target.email)
      refute Ash.get!(User, target.id, authorize?: false).is_platform_admin

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["user_id"] == target.id
      assert confirmed["result"]["is_platform_admin"] == true

      assert Ash.get!(User, target.id, authorize?: false).is_platform_admin

      [action_log] = admin_action_logs(:admin_promote, target.id)
      assert action_log.actor_id == admin.id
    end

    test "promote 已是管理员的用户 → 快速失败不建 pending" do
      admin = Fixtures.platform_admin("pa-pma-admin")
      target = Fixtures.platform_admin("pa-pma-target")

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               AdminPromoteUser.execute(%{"user_id" => target.id}, frame_for(admin))

      assert msg =~ "已是平台管理员"
      assert [] = pendings_of(admin.id)
    end

    test "两管理员时 demote 一个成功" do
      admin = Fixtures.platform_admin("pa-dm-admin")
      target = Fixtures.platform_admin("pa-dm-target")

      {:reply, _, _} =
        reply = AdminDemoteUser.execute(%{"user_id" => target.id}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["summary"] =~ "≥1"

      {:reply, _, _} =
        confirm_reply =
        ConfirmOperation.execute(%{"pending_id" => payload["pending_id"]}, frame_for(admin))

      confirmed = decode_reply(confirm_reply)
      assert confirmed["result"]["is_platform_admin"] == false

      refute Ash.get!(User, target.id, authorize?: false).is_platform_admin
      assert Ash.get!(User, admin.id, authorize?: false).is_platform_admin

      [action_log] = admin_action_logs(:admin_demote, target.id)
    end

    test "最后一名管理员不可降级：不变量错误原文透传 + pending 回滚可重试" do
      admin = Fixtures.platform_admin("pa-dl-admin")

      {:reply, _, _} =
        reply = AdminDemoteUser.execute(%{"user_id" => admin.id}, frame_for(admin))

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert msg =~ "cannot demote the last remaining platform admin"
      # effect 失败回滚 pending（MEDIUM-2 语义），管理员标记未动
      assert pending_status(pending_id) == :pending
      assert Ash.get!(User, admin.id, authorize?: false).is_platform_admin
    end

    test "确认窗口内 admin 角色被撤 → confirm 被域 policy 拒 + pending 回滚可重试" do
      # §B#7 第二段兜底：第一段门控只在 request 时拦一次，confirm 以 confirm 时刻
      # actor 调域 action，PlatformAdmin policy 必须拒绝已失权的确认。
      admin = Fixtures.platform_admin("pa-rw-admin")
      revoker = Fixtures.platform_admin("pa-rw-revoker")

      # 第一段：admin 对自建 pending（demote 自己——confirm 段自读走 ReadOwnUser
      # 仍放行，失败精确落在写 policy 上而非读 policy）
      {:reply, _, _} =
        reply = AdminDemoteUser.execute(%{"user_id" => admin.id}, frame_for(admin))

      %{"pending_id" => pending_id} = decode_reply(reply)

      # 确认窗口内：另一管理员经域 action 撤掉发起者的管理员身份
      {:ok, _} =
        admin
        |> Ash.Changeset.for_update(:demote_platform_admin, %{})
        |> Ash.update(actor: revoker)

      # confirm 时刻 actor 由服务端按会话重新解析（fresh read），PlatformAdmin policy
      # 读的是 actor struct 上的标记——撤销后到达 confirm 的 actor 已是非管理员
      admin = Ash.get!(User, admin.id, authorize?: false)
      refute admin.is_platform_admin

      # 第二段：confirm 被域 policy 拒（effect 失败 → pending 回滚）
      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert msg =~ "forbidden: platform admin required to demote users"
      assert pending_status(pending_id) == :pending

      # 被拒的 confirm 零 effect：admin_demote 留痕恰一行（revoker 的撤权）
      assert [log] = admin_action_logs(:admin_demote, admin.id)
      assert log.actor_id == revoker.id

      # 回滚后可重试：恢复身份再 confirm 同一 pending 即成功
      # （重试请求的 actor 同样是重新解析的——用域 action 返回的新 struct）
      {:ok, admin} =
        admin
        |> Ash.Changeset.for_update(:set_platform_admin, %{is_platform_admin: true})
        |> Ash.update(actor: revoker)

      assert {:reply, _, _} =
               retry_reply =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert decode_reply(retry_reply)["result"]["is_platform_admin"] == false
      refute Ash.get!(User, admin.id, authorize?: false).is_platform_admin
      assert Ash.get!(User, revoker.id, authorize?: false).is_platform_admin
    end
  end

  describe "确认流纪律" do
    test "cancel_operation：无副作用" do
      admin = Fixtures.platform_admin("pa-cc-admin")
      applicant = Fixtures.register_user("pa-cc-applicant")
      application = create_workspace_application(applicant)

      {:reply, _, _} =
        reply =
        AdminApproveWorkspaceApplication.execute(
          %{"application_id" => application.id},
          frame_for(admin)
        )

      %{"pending_id" => pending_id} = decode_reply(reply)

      {:reply, _, _} =
        cancel_reply =
        CancelOperation.execute(%{"pending_id" => pending_id}, frame_for(admin))

      assert decode_reply(cancel_reply)["status"] == "cancelled"
      assert Ash.get!(WorkspaceApplication, application.id, authorize?: false).status == :pending
      assert workspace_by_slug(application.slug) == nil
    end

    test "他人 pending 不可确认（新分派子句同受归属校验保护）" do
      admin = Fixtures.platform_admin("pa-po-admin")
      other_admin = Fixtures.platform_admin("pa-po-other")
      target = Fixtures.register_user("pa-po-target")

      {:reply, _, _} =
        reply = AdminPromoteUser.execute(%{"user_id" => target.id}, frame_for(admin))

      %{"pending_id" => pending_id} = decode_reply(reply)

      assert {:error, %Anubis.MCP.Error{message: msg}, _} =
               ConfirmOperation.execute(%{"pending_id" => pending_id}, frame_for(other_admin))

      assert msg =~ "pending operation not found"
      assert pending_status(pending_id) == :pending
      refute Ash.get!(User, target.id, authorize?: false).is_platform_admin
    end
  end
end
