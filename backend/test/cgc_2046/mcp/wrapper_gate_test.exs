defmodule Cgc2046.Mcp.WrapperGateTest do
  @moduledoc """
  架构深化 C 一致性测试：鉴权立场随工具走（工具自身 meta 声明 + Wrapper 派生门控）。

  - 派生门控集合恰为 26 个豁免工具（精确名单：3 × workspace_id: :optional +
    3 × optional+deferred 双键 + 8 × membership: :deferred + 2 × membership: :public +
    10 × workspace_id: :optional + membership: :platform_admin）
  - member-only 工具不携带豁免 meta（S10 后 33 个：原 10 + 工作台管理面 13 +
    课程教研流程 9 + 学习分析 1）
  - 未声明 meta 的工具默认门控 = member-only + workspace_id 必填（fail-closed）
  - 两个公开工具命中 `:public` 分支而非落入 optional 分支（map 子集匹配下
    子句顺序即语义，KTD3）；optional+deferred 双键工具命中 `:optional` 分支
    （同理，S1 get_role_playbook）
  - 平台治理十工具（admin_ 前缀，双键 meta）命中 `:platform_admin` 分支——
    S2 新门控族，子句置于 `:optional` 之前而不吞掉 S1 双键工具

  新工具漏声明、豁免被误删均直接红（结构性消除 wrapper 时代「删清单条目无
  编译错误、无测试断言」的删除风险）。
  """
  use Cgc2046.DataCase, async: true

  alias Anubis.Server.Context
  alias Anubis.Server.Frame
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.ToolCallLog
  alias Cgc2046.Mcp.Wrapper

  # 精确名单（与 server.ex 注册的 60 工具一一对应）
  @workspace_id_optional ~w(confirm_operation cancel_operation list_my_workspaces)
  @optional_deferred ~w(get_role_playbook discover_offerings get_my_enrollments)
  @membership_deferred ~w(save_step_output get_course_content get_course_revision get_enrollment_summary create_enrollment get_order_status start_learning_run submit_learning_attempt get_learning_state)
  @membership_public ~w(list_public_offerings get_public_offering)
  @membership_platform_admin ~w(admin_list_users admin_list_workspaces admin_list_workspace_applications admin_list_audit_logs admin_approve_workspace_application admin_reject_workspace_application admin_create_workspace admin_reassign_workspace_owner admin_promote_user admin_demote_user)
  @member_only ~w(get_workspace_context list_members list_join_requests get_workflow get_step_output create_invitation approve_join_request assign_roles save_course_content list_my_tasks) ++
                 ~w(create_course update_course launch_course close_course cancel_course list_course_enrollments confirm_enrollment reject_enrollment waive_payment list_workspace_orders refund_order retry_refund update_join_policy) ++
                 ~w(get_prep_status assign_prep_tutor claim_prep_authoring update_prep_policy submit_prep_for_check submit_prep_quality_report override_prep_gate approve_prep request_changes_prep) ++
                 ~w(get_course_learning_analytics)

  defp frame_for(user), do: Frame.new(current_user: user)

  defp tool_meta_map do
    Server.__components__(:tool)
    |> Map.new(fn tool -> {tool.name, tool.meta} end)
  end

  describe "派生门控集合 = 20 个豁免工具（精确名单）" do
    test "workspace_id: :optional = confirm_operation / cancel_operation / list_my_workspaces" do
      meta_map = tool_meta_map()

      for tool <- @workspace_id_optional do
        assert Map.get(meta_map, tool) == %{workspace_id: :optional},
               "expected #{tool} to declare workspace_id: :optional"
      end
    end

    test "optional+deferred 双键 = get_role_playbook + 学员旅程两跨台读（S1/S7）" do
      meta_map = tool_meta_map()

      for tool <- @optional_deferred do
        assert Map.get(meta_map, tool) == %{workspace_id: :optional, membership: :deferred},
               "expected #{tool} to declare workspace_id: :optional + membership: :deferred"
      end
    end

    test "membership: :deferred = save_step_output + 课程两学员侧工具 + 课程版本读 + 学员旅程三面 + 学习 v2 三件" do
      meta_map = tool_meta_map()

      for tool <- @membership_deferred do
        assert Map.get(meta_map, tool) == %{membership: :deferred},
               "expected #{tool} to declare membership: :deferred"
      end
    end

    test "membership: :public = list_public_offerings / get_public_offering（KTD3 新豁免家族）" do
      meta_map = tool_meta_map()

      for tool <- @membership_public do
        assert Map.get(meta_map, tool) == %{workspace_id: :optional, membership: :public},
               "expected #{tool} to declare workspace_id: :optional + membership: :public"
      end
    end

    test "membership: :platform_admin 双键 = admin_ 前缀十工具（S2 平台治理族）" do
      meta_map = tool_meta_map()

      for tool <- @membership_platform_admin do
        assert Map.get(meta_map, tool) == %{
                 workspace_id: :optional,
                 membership: :platform_admin
               },
               "expected #{tool} to declare workspace_id: :optional + membership: :platform_admin"
      end
    end

    test "豁免工具恰为 27 个：无遗漏、无多出" do
      exempt =
        tool_meta_map()
        |> Enum.filter(fn {_name, meta} -> meta != nil end)
        |> Map.new()

      assert Map.keys(exempt) |> Enum.sort() ==
               Enum.sort(
                 @workspace_id_optional ++
                   @optional_deferred ++
                   @membership_deferred ++ @membership_public ++ @membership_platform_admin
               )
    end

    test "member-only 工具不携带豁免 meta" do
      meta_map = tool_meta_map()

      for tool <- @member_only do
        assert Map.get(meta_map, tool) == nil, "expected #{tool} to carry no meta"
      end
    end

    test "注册工具数 = 60 且名单完备（无未收录工具）" do
      meta_map = tool_meta_map()

      assert map_size(meta_map) == 60

      assert Map.keys(meta_map) |> Enum.sort() ==
               Enum.sort(
                 @workspace_id_optional ++
                   @optional_deferred ++
                   @membership_deferred ++
                   @membership_public ++ @membership_platform_admin ++ @member_only
               )
    end

    test "公开工具命中 :public 分支而非 optional 分支（map 子集匹配下子句顺序即语义，KTD3）" do
      for tool <- @membership_public do
        assert Wrapper.gate_family(tool) == :public,
               "expected #{tool} to hit :public gate branch"
      end

      # 既有家族分支回归：子句顺序变化会把它们挤到错误分支
      assert Wrapper.gate_family("confirm_operation") == :optional
      assert Wrapper.gate_family("save_step_output") == :deferred
      assert Wrapper.gate_family("list_members") == :member_only
    end

    test "optional+deferred 双键工具命中 :optional 分支（子句顺序即语义，S1）" do
      for tool <- @optional_deferred do
        assert Wrapper.gate_family(tool) == :optional,
               "expected #{tool} to hit :optional gate branch"
      end

      assert Wrapper.gate_family("list_my_workspaces") == :optional
      assert Wrapper.gate_family("list_my_tasks") == :member_only
    end

    test "平台治理工具命中 :platform_admin 分支，S1 双键工具不被吞掉（S2 新子句顺序回归）" do
      for tool <- @membership_platform_admin do
        assert Wrapper.gate_family(tool) == :platform_admin,
               "expected #{tool} to hit :platform_admin gate branch"
      end

      # 回归：%{membership: :platform_admin} 子句置于 :optional 之前，
      # 不得吞掉 S1 的 %{workspace_id: :optional, membership: :deferred} 工具
      assert Wrapper.gate_family("get_role_playbook") == :optional
      assert Wrapper.gate_family("list_my_workspaces") == :optional
      assert Wrapper.gate_family("confirm_operation") == :optional
      # S7：学员旅程两跨台读同为双键（optional 分支，跨台锚定语义）
      assert Wrapper.gate_family("discover_offerings") == :optional
      assert Wrapper.gate_family("get_my_enrollments") == :optional
    end
  end

  describe "Wrapper 派生门控消费（fail-closed 默认）" do
    test "未声明 meta 的工具：缺 workspace_id → forbidden（D12）" do
      admin = Fixtures.platform_admin("mcp-gate-a")

      assert {:error, msg} =
               Wrapper.run(frame_for(admin), %{}, "ghost_tool", fn _, _, _ -> {:ok, %{}} end)

      assert msg =~ "workspace_id is required"
    end

    test "未声明 meta 的工具：非成员 → forbidden（不经业务 fun）" do
      admin = Fixtures.platform_admin("mcp-gate-b")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("mcp-gate-b-outsider")

      assert {:error, msg} =
               Wrapper.run(
                 frame_for(outsider),
                 %{"workspace_id" => workspace.id},
                 "ghost_tool",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )

      assert msg =~ "not a member"
    end

    test "未声明 meta 的工具：成员 + workspace_id → 放行到业务 fun" do
      admin = Fixtures.platform_admin("mcp-gate-c")
      workspace = Fixtures.create_workspace(admin)

      assert {:ok, %{called: true}} =
               Wrapper.run(
                 frame_for(admin),
                 %{"workspace_id" => workspace.id},
                 "ghost_tool",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )
    end

    test "workspace_id: :optional 工具：无 workspace_id 放行到业务 fun" do
      admin = Fixtures.platform_admin("mcp-gate-d")

      assert {:ok, %{called: true}} =
               Wrapper.run(
                 frame_for(admin),
                 %{},
                 "confirm_operation",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )
    end

    test "membership: :deferred 工具：workspace_id 仍必填" do
      admin = Fixtures.platform_admin("mcp-gate-e")

      assert {:error, msg} =
               Wrapper.run(
                 frame_for(admin),
                 %{},
                 "save_step_output",
                 fn _, _, _ -> {:ok, %{}} end
               )

      assert msg =~ "workspace_id is required"
    end

    test "membership: :deferred 工具：非成员放行到工具层判定（业务 fun 执行）" do
      admin = Fixtures.platform_admin("mcp-gate-f")
      workspace = Fixtures.create_workspace(admin)
      outsider = Fixtures.register_user("mcp-gate-f-outsider")

      assert {:ok, %{called: true}} =
               Wrapper.run(
                 frame_for(outsider),
                 %{"workspace_id" => workspace.id},
                 "get_course_content",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )
    end

    test "membership: :public 工具：零成员身份 + 无 workspace_id 放行到业务 fun（KTD3）" do
      outsider = Fixtures.register_user("mcp-gate-public-outsider")

      assert {:ok, %{called: true}} =
               Wrapper.run(
                 frame_for(outsider),
                 %{},
                 "list_public_offerings",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )
    end

    test "membership: :public 工具：无 actor 仍拒绝（actor 校验恒在）" do
      assert {:error, msg} =
               Wrapper.run(Frame.new(), %{}, "list_public_offerings", fn _, _, _ ->
                 {:ok, %{called: true}}
               end)

      assert msg =~ "unauthenticated"
    end

    test "membership: :platform_admin 工具：非平台管理员 → forbidden（不经业务 fun）" do
      outsider = Fixtures.register_user("mcp-gate-pa-outsider")

      assert {:error, msg} =
               Wrapper.run(
                 frame_for(outsider),
                 %{},
                 "admin_list_users",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )

      assert msg =~ "forbidden: platform admin required"
    end

    test "membership: :platform_admin 工具：平台管理员无 workspace_id 放行到业务 fun" do
      admin = Fixtures.platform_admin("mcp-gate-pa-admin")

      assert {:ok, %{called: true}} =
               Wrapper.run(
                 frame_for(admin),
                 %{},
                 "admin_list_users",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )
    end

    test "member-only 双面契约不动：非成员平台管理员调 member-only 工具仍 forbidden" do
      admin = Fixtures.platform_admin("mcp-gate-pa-nonmember")
      %{workspace: workspace} = Fixtures.workspace_with_member()

      assert {:error, msg} =
               Wrapper.run(
                 frame_for(admin),
                 %{"workspace_id" => workspace.id},
                 "list_members",
                 fn _, _, _ -> {:ok, %{called: true}} end
               )

      assert msg =~ "not a member"
    end
  end

  describe "归因维度落库（#228：client_name / session_id 随审计行）" do
    test "frame.context 有 clientInfo / session_id → 审计行带两维度" do
      admin = Fixtures.platform_admin("mcp-attr-a")
      workspace = Fixtures.create_workspace(admin)

      frame = %Frame{
        Frame.new(current_user: admin)
        | context: %Context{
            session_id: "sess-228",
            client_info: %{"name" => "omp", "version" => "9.9"}
          }
      }

      assert {:ok, _} =
               Wrapper.run(frame, %{"workspace_id" => workspace.id}, "ghost_tool", fn _, _, _ ->
                 {:ok, %{}}
               end)

      [log] = Ash.read!(ToolCallLog, authorize?: false)
      assert log.client_name == "omp"
      assert log.session_id == "sess-228"
    end

    test "frame.context 缺 clientInfo / session_id → 审计行落 nil 不炸" do
      admin = Fixtures.platform_admin("mcp-attr-b")
      workspace = Fixtures.create_workspace(admin)

      assert {:ok, _} =
               Wrapper.run(
                 frame_for(admin),
                 %{"workspace_id" => workspace.id},
                 "ghost_tool",
                 fn _, _, _ -> {:ok, %{}} end
               )

      [log] = Ash.read!(ToolCallLog, authorize?: false)
      assert is_nil(log.client_name)
      assert is_nil(log.session_id)
    end
  end
end
