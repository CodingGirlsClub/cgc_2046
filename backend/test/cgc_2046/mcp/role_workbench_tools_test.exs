defmodule Cgc2046.Mcp.RoleWorkbenchToolsTest do
  @moduledoc """
  角色工作台基座三工具测试（role-agent-journeys-v2 S1，直接调 tool execute/2，不走 HTTP）。

  - list_my_workspaces：actor 锚定跨工作台读（成员资格收窄、角色字符串、
    名称排序、is_platform_admin、空成员资格、审计）
  - get_role_playbook：四角色授权矩阵（learner 全员 / tutor 角色 / workspace_admin
    owner|admin / platform_admin 全局标记）、workspace_id 必填角色缺参、未知角色、审计
  - list_my_tasks：member-only 门（非成员 forbidden）、owner 见 pending 加入申请、
    普通成员空集、跨工作台不泄漏（R8 v0 = PendingApprovals 聚合；prep 任务行 S5 接入）
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Frame

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.ToolCallLog

  alias Cgc2046.Mcp.Tools.{GetRolePlaybook, ListMyTasks, ListMyWorkspaces}

  require Ash.Query

  defp frame_for(user), do: Frame.new(current_user: user)

  defp decode_reply({:reply, response, _frame}) do
    [content] = response.content
    Jason.decode!(content["text"])
  end

  defp decode_error({:error, %Anubis.MCP.Error{reason: :execution_error, message: msg}, _frame}),
    do: msg

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

  describe "list_my_workspaces" do
    test "返回 actor 全部工作台（角色字符串 + 按名称排序）+ is_platform_admin" do
      admin = Fixtures.platform_admin("rw-list-admin")
      beta = Fixtures.create_workspace(admin, %{name: "Beta WS"})
      alpha = Fixtures.create_workspace(admin, %{name: "Alpha WS"})

      assert {:reply, _, _} = reply = ListMyWorkspaces.execute(%{}, frame_for(admin))
      payload = decode_reply(reply)

      assert payload["is_platform_admin"] == true
      assert Enum.map(payload["workspaces"], & &1["name"]) == ["Alpha WS", "Beta WS"]

      [alpha_row, beta_row] = payload["workspaces"]
      assert alpha_row["workspace_id"] == alpha.id
      assert alpha_row["slug"] == alpha.slug
      assert alpha_row["roles"] == ["owner"]
      assert beta_row["workspace_id"] == beta.id

      [log] = tool_logs_for(admin.id, "list_my_workspaces")
      assert log.result_status == :ok
    end

    test "多角色并集为字符串列表；不属于 actor 的工作台不出现；非管理员 is_platform_admin = false" do
      admin = Fixtures.platform_admin("rw-iso-admin")
      other = Fixtures.create_workspace(admin, %{name: "Other WS"})

      user = Fixtures.register_user("rw-iso-user")
      mine = Fixtures.create_workspace(admin, %{name: "Mine WS"})
      Fixtures.add_member(mine, user, [:tutor, :learner])

      assert {:reply, _, _} = reply = ListMyWorkspaces.execute(%{}, frame_for(user))
      payload = decode_reply(reply)

      assert payload["is_platform_admin"] == false

      assert [row] = payload["workspaces"]
      assert row["workspace_id"] == mine.id
      assert Enum.sort(row["roles"]) == ["learner", "tutor"]
      refute row["workspace_id"] == other.id
    end

    test "无成员资格的用户 → 空列表（不报错）" do
      user = Fixtures.register_user("rw-empty")

      assert {:reply, _, _} = reply = ListMyWorkspaces.execute(%{}, frame_for(user))
      payload = decode_reply(reply)

      assert payload["workspaces"] == []
      assert payload["is_platform_admin"] == false
    end
  end

  describe "get_role_playbook" do
    test "learner：任何已认证用户可取（含零成员资格用户）" do
      user = Fixtures.register_user("rw-pb-learner")

      assert {:reply, _, _} =
               reply =
               GetRolePlaybook.execute(%{"role" => "learner"}, frame_for(user))

      payload = decode_reply(reply)
      assert payload["role"] == "learner"
      assert payload["version"] == "2026-08-29.1"
      assert payload["content"] =~ "学习模式"
      # S1 吸收原 Learning.AgentInstructions 八步循环段落随版本号分发
      assert payload["content"] =~ "八步循环"
      assert payload["content"] =~ "save_learning_records"

      [log] = tool_logs_for(user.id, "get_role_playbook")
      assert log.result_status == :ok
    end

    test "tutor：非 tutor 成员拒绝；tutor 成员可取" do
      admin = Fixtures.platform_admin("rw-pb-tutor-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("rw-pb-tutor-member")
      Fixtures.add_member(workspace, member, [])

      assert {:error, _, _} =
               error =
               GetRolePlaybook.execute(
                 %{"role" => "tutor", "workspace_id" => workspace.id},
                 frame_for(member)
               )

      assert decode_error(error) =~ "forbidden"

      [log] = tool_logs_for(member.id, "get_role_playbook")
      assert log.result_status == :forbidden

      tutor = Fixtures.register_user("rw-pb-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])

      assert {:reply, _, _} =
               reply =
               GetRolePlaybook.execute(
                 %{"role" => "tutor", "workspace_id" => workspace.id},
                 frame_for(tutor)
               )

      payload = decode_reply(reply)
      assert payload["role"] == "tutor"
      # S5 bump:tutor playbook 加教研旅程动线（认领/质检/评分/审核链路）
      assert payload["version"] == "2026-08-29.3"
      assert payload["content"] =~ "教研模式"
      # S1 吸收原 Curriculum.AgentInstructions 起草规则段落随版本号分发
      assert payload["content"] =~ "id 稳定纪律"
      assert payload["content"] =~ "save_course_content"
      # S4:版本纪律章节随版本号分发
      assert payload["content"] =~ "base_version"
      assert payload["content"] =~ "version_conflict"
      # S5:教研旅程章节随版本号分发
      assert payload["content"] =~ "claim_prep_authoring"
      assert payload["content"] =~ "submit_prep_quality_report"
    end

    test "tutor：缺 workspace_id → 明确报错（非 forbidden 审计）" do
      user = Fixtures.register_user("rw-pb-tutor-nows")

      assert {:error, _, _} =
               error =
               GetRolePlaybook.execute(%{"role" => "tutor"}, frame_for(user))

      assert decode_error(error) =~ "workspace_id is required for role tutor"

      [log] = tool_logs_for(user.id, "get_role_playbook")
      assert log.result_status == :error
    end

    test "workspace_admin：普通成员拒绝；owner 与 admin 可取" do
      platform_admin = Fixtures.platform_admin("rw-pb-wsadmin-platform")
      workspace = Fixtures.create_workspace(platform_admin)

      member = Fixtures.register_user("rw-pb-wsadmin-member")
      Fixtures.add_member(workspace, member, [])

      assert {:error, _, _} =
               error =
               GetRolePlaybook.execute(
                 %{"role" => "workspace_admin", "workspace_id" => workspace.id},
                 frame_for(member)
               )

      assert decode_error(error) =~ "forbidden"

      # owner（create_workspace 的 after_action 入座）
      assert {:reply, _, _} =
               owner_reply =
               GetRolePlaybook.execute(
                 %{"role" => "workspace_admin", "workspace_id" => workspace.id},
                 frame_for(platform_admin)
               )

      assert decode_reply(owner_reply)["role"] == "workspace_admin"

      admin_member = Fixtures.register_user("rw-pb-wsadmin-admin")
      Fixtures.add_member(workspace, admin_member, [:admin])

      assert {:reply, _, _} =
               admin_reply =
               GetRolePlaybook.execute(
                 %{"role" => "workspace_admin", "workspace_id" => workspace.id},
                 frame_for(admin_member)
               )

      assert decode_reply(admin_reply)["content"] =~ "工作台管理模式"
    end

    test "platform_admin：非管理员拒绝；平台管理员可取（无需 workspace_id）" do
      user = Fixtures.register_user("rw-pb-padmin-user")

      assert {:error, _, _} =
               error =
               GetRolePlaybook.execute(%{"role" => "platform_admin"}, frame_for(user))

      assert decode_error(error) =~ "forbidden"

      admin = Fixtures.platform_admin("rw-pb-padmin")

      assert {:reply, _, _} =
               reply =
               GetRolePlaybook.execute(%{"role" => "platform_admin"}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["role"] == "platform_admin"
      assert payload["content"] =~ "平台治理模式"
    end

    test "未知 role → 错误并列明合法角色" do
      user = Fixtures.register_user("rw-pb-unknown")

      assert {:error, _, _} =
               error =
               GetRolePlaybook.execute(%{"role" => "superuser"}, frame_for(user))

      msg = decode_error(error)
      assert msg =~ "unknown role"
      assert msg =~ "learner"
      assert msg =~ "tutor"
      assert msg =~ "workspace_admin"
      assert msg =~ "platform_admin"

      [log] = tool_logs_for(user.id, "get_role_playbook")
      assert log.result_status == :error
    end
  end

  describe "list_my_tasks" do
    test "非成员 → forbidden（member-only 门，不经业务）+ 审计" do
      admin = Fixtures.platform_admin("rw-tasks-admin")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("rw-tasks-outsider")

      assert {:error, _, _} =
               error =
               ListMyTasks.execute(%{"workspace_id" => workspace.id}, frame_for(outsider))

      assert decode_error(error) =~ "not a member"

      [log] = tool_logs_for(outsider.id, "list_my_tasks")
      assert log.result_status == :forbidden
    end

    test "owner 见本工作台 pending 加入申请行" do
      admin = Fixtures.platform_admin("rw-tasks-owner")
      workspace = Fixtures.create_workspace(admin)
      applicant = Fixtures.register_user("rw-tasks-applicant")
      join_request = create_join_request(workspace, applicant)

      assert {:reply, _, _} =
               reply =
               ListMyTasks.execute(%{"workspace_id" => workspace.id}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["workspace_id"] == workspace.id
      assert payload["count"] == 1

      [task] = payload["tasks"]
      assert task["kind"] == "join_request"
      assert task["id"] == join_request.id
      assert task["workspace_slug"] == workspace.slug

      [log] = tool_logs_for(admin.id, "list_my_tasks")
      assert log.result_status == :ok
    end

    test "普通成员（无管理角色）→ 空任务列表" do
      admin = Fixtures.platform_admin("rw-tasks-member-admin")
      workspace = Fixtures.create_workspace(admin)
      member = Fixtures.register_user("rw-tasks-member")
      Fixtures.add_member(workspace, member, [])

      _join_request = create_join_request(workspace, Fixtures.register_user("rw-tasks-app2"))

      assert {:reply, _, _} =
               reply =
               ListMyTasks.execute(%{"workspace_id" => workspace.id}, frame_for(member))

      payload = decode_reply(reply)
      assert payload["count"] == 0
      assert payload["tasks"] == []
    end

    test "跨工作台过滤：他处工作台的待办不泄漏进本工作台" do
      admin = Fixtures.platform_admin("rw-tasks-iso-admin")
      workspace = Fixtures.create_workspace(admin, %{name: "Iso WS"})
      other = Fixtures.create_workspace(admin, %{name: "Other WS"})

      _other_jr = create_join_request(other, Fixtures.register_user("rw-tasks-iso-app"))

      assert {:reply, _, _} =
               reply =
               ListMyTasks.execute(%{"workspace_id" => workspace.id}, frame_for(admin))

      payload = decode_reply(reply)
      assert payload["count"] == 0
      assert payload["tasks"] == []

      # 对侧工作台能看到自己的待办（证明过滤方向正确，而非聚合为空）
      assert {:reply, _, _} =
               other_reply =
               ListMyTasks.execute(%{"workspace_id" => other.id}, frame_for(admin))

      assert decode_reply(other_reply)["count"] == 1
    end

    test "工作台不存在 → member-only 门同样 fail-closed（membership 查不到即 forbidden）" do
      admin = Fixtures.platform_admin("rw-tasks-ghost-admin")

      assert {:error, _, _} =
               error =
               ListMyTasks.execute(
                 %{"workspace_id" => Ash.UUID.generate()},
                 frame_for(admin)
               )

      assert decode_error(error) =~ "not a member"

      [log] = tool_logs_for(admin.id, "list_my_tasks")
      assert log.result_status == :forbidden
    end
  end
end
