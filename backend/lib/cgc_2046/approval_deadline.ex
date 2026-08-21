defmodule Cgc2046.ApprovalDeadline do
  @moduledoc """
  审批期限（approval deadline）派生的唯一真源。

  （2026-08-14 审批期限深化，架构评审候选②；plan
  docs/plans/2026-08-14-005-approval-deadline-deepening.md D1-D8 全锁定）

  收敛前，deadline 派生公式两份平行拷贝（ApprovalExpiryWorker.approval_overdue?
  与 ApprovalReminderWorker.approval_deadline）、7 天默认常量四份
  （@default_approval_timeout_days 散落四资源）；本 module 收编为**唯一实现**。
  ApprovalReminderWorker / ApprovalExpiryWorker 与四资源创建期只调本模块，
  不再自带派生公式与常量。

  ## nil 语义（单点）

  `derive/1` 返回 `nil` = **永不过期**：不参与过期扫描（`overdue?/2` 恒 false），
  也不进入提醒窗口（`in_window?/3` 不适用）。WorkflowRun 的
  `definition.approval_timeout = nil`（F7 方案 A）即此语义；列实体
  `approval_deadline`/`expires_at` 列为空同此。

  ## interface

  - `derive/1`：列实体（Enrollment / JoinRequest / Sponsorship /
    WorkspaceApplication）读 `approval_deadline` 列；Invitation 读 `expires_at` 列
    （邀请过期，非审批，由本模块统一读列不引入第二个派生公式）；WorkflowRun =
    `updated_at + definition.approval_timeout` 内存派生（调用方需先
    `Ash.Query.load(definition: [:approval_timeout])`，load 路径保持）；
  - `not_expired?/2`：**放行谓词**（deadline 严格 `> now`，==now 不放行；nil 恒 true）
    ——claim 守卫与投递守卫用；
  - `overdue?/2`：**扫中谓词**（deadline 已严格过点 `< now`，==now 不算过期）——
    过期扫描用；与 `not_expired?/2` 是**不对称对偶**（nil 侧相反：not_expired?
    nil→true / overdue? nil→false；==now 侧双双 false），不可互相代用；
  - `in_window?/3`：半开区间 `(now, window_end]`（左开右闭，与收敛前
    ApprovalReminderWorker 窗口谓词一致）；
  - `default_timeout_days/0`：四资源创建期默认审批期限的唯一来源；
  - `default_deadline_from_now/0`：创建期默认截止时间（`now + 默认天数`）。
    **必须以捕获形态传给 Ash DSL**（`&Cgc2046.ApprovalDeadline.default_deadline_from_now/0`）
    ——直接传求值结果会被 DSL 宏冻结成编译期常量（= release 构建时刻 + 7 天），
    构建 7 天后所有新记录生来即过期（2026-08-21 实证，见
    test/cgc_2046/no_eager_dsl_timestamp_test.exs 源码门禁）。

  `ExpiryWorker` 扫描规格（@expiry_specs）与 `ReminderWorker` 窗口大小（48h）不在
  本模块——sweep 只有 AEW 一个调用方、窗口是 ARW 私有常量（D7）。
  """

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Workflows.WorkflowRun

  @default_timeout_days 7

  @doc """
  派生审批截止时间。

  - 列实体（Enrollment / JoinRequest / Sponsorship / WorkspaceApplication）：读
    `approval_deadline` 列；Invitation 读 `expires_at` 列；
  - WorkflowRun：`updated_at + definition.approval_timeout`（内存派生，definition
    需已 load `:approval_timeout`；definition 未 load 或 timeout 为 nil 均返回 nil）。

  `nil` = 永不过期。
  """
  @spec derive(map()) :: DateTime.t() | nil
  def derive(%WorkflowRun{} = run) do
    case run.definition do
      %{approval_timeout: nil} ->
        nil

      %{approval_timeout: timeout} ->
        DateTime.add(run.updated_at, timeout, :second)

      # definition 未 load（调用方契约：`Ash.Query.load(definition: [:approval_timeout])`）。
      # 防御性按永不过期处理——未知 timeout 不猜测，安全方向与 nil 语义一致。
      _ ->
        nil
    end
  end

  def derive(%Invitation{} = invitation), do: invitation.expires_at
  def derive(record), do: record.approval_deadline

  @doc """
  审批期限是否已严格过点（`deadline < now`，deadline == now 不算过期）。

  `derive/1` 返回 nil（永不过期）时恒 false。
  """
  @spec overdue?(map(), DateTime.t()) :: boolean()
  def overdue?(record, now) do
    case derive(record) do
      nil -> false
      deadline -> DateTime.compare(deadline, now) == :lt
    end
  end

  @doc """
  审批期限是否未过（**放行谓词**：`deadline > now` 严格大于，deadline == now 不放行）。

  `derive/1` 返回 nil（永不过期）时恒 true。

  与 `overdue?/2` 是**不对称对偶**（见 moduledoc）：nil 侧相反（not_expired?
  nil→true / overdue? nil→false）、==now 侧双双 false——`not_expired?` 是放行谓词
  （claim 守卫 / 投递守卫），`overdue?` 是扫中谓词（过期扫描），不可互相代用。
  """
  @spec not_expired?(map(), DateTime.t()) :: boolean()
  def not_expired?(record, now) do
    case derive(record) do
      nil -> true
      deadline -> DateTime.compare(deadline, now) == :gt
    end
  end

  @doc """
  deadline 是否落在提醒窗口 `(now, window_end]`（左开右闭，半开区间）。

  已过期（deadline <= now）不在窗口（过期由 ExpiryWorker 负责转 expired）；
  超 window_end 的留给后续拍。语义与收敛前 ApprovalReminderWorker 窗口谓词一致。
  """
  @spec in_window?(DateTime.t(), DateTime.t(), DateTime.t()) :: boolean()
  def in_window?(deadline, now, window_end) do
    DateTime.compare(deadline, now) == :gt and DateTime.compare(deadline, window_end) != :gt
  end

  @doc "创建期默认审批期限（天）。唯一真源，四资源创建设值统一改调本函数。"
  @spec default_timeout_days() :: non_neg_integer()
  def default_timeout_days, do: @default_timeout_days

  @doc """
  创建期默认审批截止时间（`DateTime.utc_now() + default_timeout_days()` 天）。

  Ash DSL 里必须传捕获 `&Cgc2046.ApprovalDeadline.default_deadline_from_now/0`
  （0-arity 函数由 Ash 在每次 action 执行时调用）；传 `default_deadline_from_now()`
  求值结果会被 `set_attribute` 宏冻结为编译期常量——见 moduledoc。
  """
  @spec default_deadline_from_now() :: DateTime.t()
  def default_deadline_from_now do
    DateTime.add(DateTime.utc_now(), @default_timeout_days, :day)
  end
end
