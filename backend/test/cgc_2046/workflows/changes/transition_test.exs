defmodule Cgc2046.Workflows.Changes.TransitionTest do
  @moduledoc """
  Transition change 契约单测（PR-G D7）：from 匹配 force_change / from 不匹配
  add_error（错误串逐字「cannot <verb> from status=<s>」）/ cleanup 开关
  （cleanup_checkpoint: true 挂 after_transaction）。

  纯 changeset 级（apply_action，不落库）；复杂执行闭环（start_run/resume_signal
  调引擎）不在此覆盖——守卫语义由 workflow_run_test 98-349 既有用例守护。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Workflows.WorkflowRun

  # Transition change 在 for_update（changeset 构造）阶段执行：guard 结果直接
  # 从 changeset 读取（status 属性被 force 或 errors 挂上），无需落库/apply。
  defp run_changeset(status, action) do
    record = %WorkflowRun{
      id: Ecto.UUID.generate(),
      workspace_id: Ecto.UUID.generate(),
      definition_id: Ecto.UUID.generate(),
      definition_version: 1,
      partition_id: Ecto.UUID.generate(),
      status: status,
      version: 1
    }

    Ash.Changeset.for_update(record, action)
  end

  describe "from 匹配 → force_change status 为 to" do
    test "start: pending → running" do
      cs = run_changeset(:pending, :start)
      assert Ash.Changeset.get_attribute(cs, :status) == :running
    end

    test "complete: waiting → succeeded（cleanup_checkpoint: true 的守卫本身）" do
      cs = run_changeset(:waiting, :complete)
      assert Ash.Changeset.get_attribute(cs, :status) == :succeeded
    end
  end

  describe "from 不匹配 → add_error（错误串逐字「cannot <verb> from status=<s>」）" do
    test "start from running → cannot start from status=running" do
      cs = run_changeset(:running, :start)
      assert Enum.any?(cs.errors, &(&1.message == "cannot start from status=running"))
    end

    test "fail from pending（from 列表外）→ cannot fail from status=pending" do
      cs = run_changeset(:pending, :fail)
      assert Enum.any?(cs.errors, &(&1.message == "cannot fail from status=pending"))
    end

    test "cancel from succeeded（from 列表外）→ cannot cancel from status=succeeded" do
      cs = run_changeset(:succeeded, :cancel)
      assert Enum.any?(cs.errors, &(&1.message == "cannot cancel from status=succeeded"))
    end
  end

  describe "cleanup 开关" do
    test "cleanup_checkpoint: true 挂 after_transaction（complete）" do
      cs = run_changeset(:waiting, :complete)
      refute cs.after_transaction == []
    end

    test "cleanup_checkpoint: true 挂 after_transaction（cancel）" do
      cs = run_changeset(:waiting, :cancel)
      refute cs.after_transaction == []
    end

    test "cleanup_checkpoint 缺省（false）不挂 after_transaction（start 非终态）" do
      cs = run_changeset(:pending, :start)
      assert cs.after_transaction == []
    end
  end
end
