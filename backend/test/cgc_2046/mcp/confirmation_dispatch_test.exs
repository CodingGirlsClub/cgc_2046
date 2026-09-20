defmodule Cgc2046.Mcp.ConfirmationDispatchTest do
  @moduledoc """
  确认流分派派生契约（2026-09-08 架构评审候选②）：

  - 分派源 = 组件注册表（`Server.__components__(:tool)` 的 name → handler），
    凡导出 `execute_confirmed/2` 的注册工具即可被 `Wrapper.executor_for/1` 分派——
    「工具已注册但 Confirmation 漏加 execute/3 子句」在结构上不可能存在
  - 精确名单钉住确认流工具：新增确认流工具必须导出 execute_confirmed/2
    并注册，否则本文件直接红（与 wrapper_gate_test 的名单惯例同款）
  - 非确认流工具与未知工具名 → `:error`（Confirmation 侧映 "no executor" 文案，
    端到端行为由 confirmation_race_test 钉死）
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Mcp.Server
  alias Cgc2046.Mcp.Wrapper

  # 确认流工具精确名单（two-tool 写族：成员管理 3 + 平台治理 12 +
  # 工作台管理面 16（#676 draft 删除后）+ 课程教研流程 3 + 押金补救 1（#545）+
  # 招募批次三件（#747 campaign 运营，create 为直接写不入列））
  @confirmation_tools ~w(create_invitation approve_join_request assign_roles) ++
                        ~w(admin_approve_workspace_application admin_reject_workspace_application admin_create_workspace admin_reassign_workspace_owner admin_promote_user admin_demote_user admin_create_initiative admin_update_initiative admin_open_initiative admin_close_initiative admin_cancel_initiative admin_upsert_initiative_rule) ++
                        ~w(update_course launch_course close_course cancel_course delete_course update_event launch_event close_event cancel_event delete_event confirm_enrollment reject_enrollment waive_payment refund_order retry_refund update_join_policy) ++
                        ~w(update_recruitment_cohort open_recruitment_cohort close_recruitment_cohort) ++
                        ~w(update_prep_policy override_prep_gate approve_prep) ++
                        ~w(unforfeit_order) ++
                        ~w(admin_soft_delete_wish admin_soft_delete_wish_comment admin_send_flashback_outreach admin_resend_flashback_outreach)

  defp registered_tools do
    Server.__components__(:tool) |> Map.new(fn tool -> {tool.name, tool.handler} end)
  end

  describe "Wrapper.executor_for/1 派生分派" do
    test "确认流工具集合恰为精确名单（导出 execute_confirmed/2 的注册工具）" do
      dispatchable =
        registered_tools()
        |> Enum.filter(fn {_name, handler} ->
          Code.ensure_loaded?(handler) and function_exported?(handler, :execute_confirmed, 2)
        end)
        |> Enum.map(fn {name, _handler} -> name end)
        |> Enum.sort()

      assert dispatchable == Enum.sort(@confirmation_tools)
    end

    test "每个确认流工具分派到自身 handler module" do
      registered = registered_tools()

      for name <- @confirmation_tools do
        assert {:ok, handler} = Wrapper.executor_for(name)
        assert handler == Map.fetch!(registered, name)
      end
    end

    test "非确认流工具与未知工具名 → :error" do
      # 直接写工具（无 execute_confirmed/2）
      assert :error = Wrapper.executor_for("save_course_content")
      # 内置确认/取消工具自身不进分派
      assert :error = Wrapper.executor_for("confirm_operation")
      assert :error = Wrapper.executor_for("cancel_operation")
      # 数据异常：pending.tool 指向未注册名
      assert :error = Wrapper.executor_for("no_such_tool")
    end
  end
end
