defmodule Cgc2046.ApprovalDeadlineTest do
  @moduledoc """
  审批期限派生唯一真源（Cgc2046.ApprovalDeadline）纯函数单测。

  覆盖 D2 interface 四函数：derive/1（列实体读列 + WorkflowRun 内存派生，含
  definition nil / timeout nil）、overdue?/2（deadline == now 边界）、in_window?/3
  （(now, window_end] 半开区间）、default_timeout_days/0。

  关键守卫（PR-D 验收）：:derived 分支里 timeout nil 的 run 永不被扫——derive 返回
  nil 时 overdue? 恒 false（防 specs 化把派生路径误并纯 SQL）。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Workflows.WorkflowRun

  describe "derive/1 列实体" do
    test "读 approval_deadline 列（Enrollment/JoinRequest/Sponsorship/WorkspaceApplication）" do
      deadline = DateTime.utc_now()

      for record <- [
            %{approval_deadline: deadline},
            %{approval_deadline: deadline, status: :pending},
            %{approval_deadline: deadline, workspace_id: "ws"}
          ] do
        assert ApprovalDeadline.derive(record) == deadline
      end
    end

    test "approval_deadline = nil → nil（永不过期）" do
      assert ApprovalDeadline.derive(%{approval_deadline: nil}) == nil
    end

    test "Invitation 读 expires_at 列（邀请过期，非 approval_deadline）" do
      deadline = DateTime.utc_now()

      assert ApprovalDeadline.derive(%Invitation{expires_at: deadline}) == deadline
    end

    test "Invitation expires_at = nil → nil（存量及 member 邀请默认，永不扫中）" do
      assert ApprovalDeadline.derive(%Invitation{expires_at: nil}) == nil
    end
  end

  describe "derive/1 WorkflowRun 内存派生" do
    test "updated_at + definition.approval_timeout（秒）" do
      now = DateTime.utc_now()
      run = %WorkflowRun{updated_at: now, definition: %{approval_timeout: 3_600}}

      assert ApprovalDeadline.derive(run) == DateTime.add(now, 3_600, :second)
    end

    test "timeout = nil → nil（F7 方案 A 无超时；关键守卫：永不被扫）" do
      now = DateTime.utc_now()

      run = %WorkflowRun{
        updated_at: DateTime.add(now, -86_400),
        definition: %{approval_timeout: nil}
      }

      assert ApprovalDeadline.derive(run) == nil
      refute ApprovalDeadline.overdue?(run, now)
    end

    test "definition 未 load → nil（调用方契约：load definition: [:approval_timeout]）" do
      now = DateTime.utc_now()
      run = %WorkflowRun{updated_at: DateTime.add(now, -86_400), definition: nil}

      assert ApprovalDeadline.derive(run) == nil
      refute ApprovalDeadline.overdue?(run, now)
    end
  end

  describe "overdue?/2" do
    test "deadline 已严格过点 → true" do
      now = DateTime.utc_now()
      record = %{approval_deadline: DateTime.add(now, -1, :second)}

      assert ApprovalDeadline.overdue?(record, now)
    end

    test "deadline == now → false（严格小于，不把恰好在 now 的当过期）" do
      now = DateTime.utc_now()
      record = %{approval_deadline: now}

      refute ApprovalDeadline.overdue?(record, now)
    end

    test "deadline 未到 → false" do
      now = DateTime.utc_now()
      record = %{approval_deadline: DateTime.add(now, 1, :second)}

      refute ApprovalDeadline.overdue?(record, now)
    end

    test "derive nil（永不过期）→ 恒 false" do
      now = DateTime.utc_now()
      refute ApprovalDeadline.overdue?(%{approval_deadline: nil}, now)
    end
  end

  describe "in_window?/3 半开区间 (now, window_end]" do
    test "deadline 落在窗口内 → true" do
      now = DateTime.utc_now()
      window_end = DateTime.add(now, 48, :hour)
      deadline = DateTime.add(now, 24, :hour)

      assert ApprovalDeadline.in_window?(deadline, now, window_end)
    end

    test "deadline == now → false（左开：已过期的不提醒）" do
      now = DateTime.utc_now()
      window_end = DateTime.add(now, 48, :hour)

      refute ApprovalDeadline.in_window?(now, now, window_end)
    end

    test "deadline == window_end → true（右闭）" do
      now = DateTime.utc_now()
      window_end = DateTime.add(now, 48, :hour)

      assert ApprovalDeadline.in_window?(window_end, now, window_end)
    end

    test "deadline < now → false" do
      now = DateTime.utc_now()
      window_end = DateTime.add(now, 48, :hour)
      deadline = DateTime.add(now, -1, :second)

      refute ApprovalDeadline.in_window?(deadline, now, window_end)
    end

    test "deadline > window_end → false（留给后续拍）" do
      now = DateTime.utc_now()
      window_end = DateTime.add(now, 48, :hour)
      deadline = DateTime.add(window_end, 1, :second)

      refute ApprovalDeadline.in_window?(deadline, now, window_end)
    end
  end

  describe "default_timeout_days/0" do
    test "创建期默认审批期限为 7 天" do
      assert ApprovalDeadline.default_timeout_days() == 7
    end
  end
end
