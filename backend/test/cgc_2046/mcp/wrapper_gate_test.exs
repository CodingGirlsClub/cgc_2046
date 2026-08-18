defmodule Cgc2046.Mcp.WrapperGateTest do
  @moduledoc """
  架构深化 C 一致性测试：鉴权立场随工具走（工具自身 meta 声明 + Wrapper 派生门控）。

  - 派生门控集合恰为 6 个豁免工具（精确名单：2 × workspace_id: :optional +
    4 × membership: :deferred）
  - member-only 工具不携带豁免 meta
  - 未声明 meta 的工具默认门控 = member-only + workspace_id 必填（fail-closed）

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

  # 精确名单（与 server.ex 注册的 12 工具一一对应）
  @workspace_id_optional ~w(confirm_operation cancel_operation)
  @membership_deferred ~w(save_step_output get_course_content get_learning_records save_learning_records)
  @member_only ~w(get_workspace_context list_members get_workflow get_step_output create_invitation save_course_content)

  defp frame_for(user), do: Frame.new(current_user: user)

  defp tool_meta_map do
    Server.__components__(:tool)
    |> Map.new(fn tool -> {tool.name, tool.meta} end)
  end

  describe "派生门控集合 = 6 个豁免工具（精确名单）" do
    test "workspace_id: :optional = confirm_operation / cancel_operation" do
      meta_map = tool_meta_map()

      for tool <- @workspace_id_optional do
        assert Map.get(meta_map, tool) == %{workspace_id: :optional},
               "expected #{tool} to declare workspace_id: :optional"
      end
    end

    test "membership: :deferred = save_step_output + 课程三学员侧工具" do
      meta_map = tool_meta_map()

      for tool <- @membership_deferred do
        assert Map.get(meta_map, tool) == %{membership: :deferred},
               "expected #{tool} to declare membership: :deferred"
      end
    end

    test "豁免工具恰为 6 个：无遗漏、无多出" do
      exempt =
        tool_meta_map()
        |> Enum.filter(fn {_name, meta} -> meta != nil end)
        |> Map.new()

      assert Map.keys(exempt) |> Enum.sort() ==
               Enum.sort(@workspace_id_optional ++ @membership_deferred)
    end

    test "member-only 工具不携带豁免 meta" do
      meta_map = tool_meta_map()

      for tool <- @member_only do
        assert Map.get(meta_map, tool) == nil, "expected #{tool} to carry no meta"
      end
    end

    test "注册工具数 = 12 且名单完备（无未收录工具）" do
      meta_map = tool_meta_map()

      assert Map.keys(meta_map) |> Enum.sort() ==
               Enum.sort(@workspace_id_optional ++ @membership_deferred ++ @member_only)
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
