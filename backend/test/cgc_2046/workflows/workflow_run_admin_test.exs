defmodule Cgc2046.Workflows.WorkflowRunAdminTest do
  @moduledoc """
  H5 AshAdmin 暴露面收口：WorkflowRun 的 facts/input_snapshot/steps 不得经
  admin 列表页或详情页展示内容。

  ash_admin 无 show 页属性排除 DSL（deps 源码实证：show 页渲染全部 attribute；
  `table_columns` 只控列表页；`show_calculations` 默认 [] 使计算不进详情页；
  `show_sensitive_fields` 是敏感遮罩的豁免清单）。故机制组合为：列表页
  table_columns 排除三字段 + 详情页 sensitive? 遮罩（--redacted--，管理员
  显式点击才揭示）+ steps 计算默认不入 show_calculations。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Workflows.WorkflowRun

  test "admin 列表列不含 facts/input_snapshot/steps" do
    columns = AshAdmin.Resource.table_columns(WorkflowRun)

    refute :facts in columns
    refute :input_snapshot in columns
    refute :steps in columns
  end

  test "详情页计算清单不含 steps（默认不渲染任何计算）" do
    refute :steps in AshAdmin.Resource.show_calculations(WorkflowRun)
  end

  test "facts/input_snapshot 属性带 sensitive? 遮罩且未被豁免" do
    for name <- [:facts, :input_snapshot] do
      assert Ash.Resource.Info.attribute(WorkflowRun, name).sensitive?,
             "#{name} 应保持 sensitive?（详情页 --redacted-- 遮罩）"
    end

    show_sensitive = AshAdmin.Resource.show_sensitive_fields(WorkflowRun)

    refute :facts in show_sensitive
    refute :input_snapshot in show_sensitive
  end
end
