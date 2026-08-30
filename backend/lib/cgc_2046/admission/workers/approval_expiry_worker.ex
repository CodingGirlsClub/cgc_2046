defmodule Cgc2046.Admission.Workers.ApprovalExpiryWorker do
  @moduledoc """
  审批超时扫描 worker（0C；Oban cron 每 5 分钟一拍，见 config.exs）。

  把「读时惰性计算过期」升级为「主动落库过期」，六份扫描由 @expiry_specs
  声明式规格驱动（列实体 SQL 下推过滤 + WorkflowRun 内存派生）：

  1. `JoinRequest`（accounts）：`status=pending 且 approval_deadline 已过` → 走既有
     `:expire` 领域 action 转 expired。落地 join_request.ex 的 TODO：「引入
     Quantum/Oban 定时器后改为主动转换，惰性计算作为兜底」（前端 ApprovalChip 的
     读时计算继续作为兜底，不受影响）。
  2. `WorkflowRun`（workflows）：F7 方案 A——`status=waiting 且 definition
     .approval_timeout 过点` → 走既有 `:expire` 领域 action（waiting → expired，
     含 checkpoint 终态清理）。deadline = run 进入 waiting 的时间（`updated_at`，
     每次 waiting 迁移刷新，重进 waiting 重新计窗）+ approval_timeout；
     `approval_timeout = nil` = 无超时，永不扫中。pending（未进入审批等待）不扫。
  3. `WorkspaceApplication`（accounts，全局资源）：`status=pending 且 approval_deadline
     已过` → 走既有 `:expire` 领域 action 转 expired（Platform Admin Dashboard R6/R7
     申请审批队列；全局资源无 tenant，update 不带 tenant）。
  4. `Invitation`（accounts，租户资源）：`status=active 且 expires_at 已过` → 走
     `:expire` 领域 action 转 expired（#114，落地 invitation.ex「引入定时器后主动
     落库」的既有 TODO；读时 effective_status 计算继续作为扫描间隙的兜底）。
     `expires_at = nil` 的邀请（存量及 member 邀请默认）永不扫中。

  本 worker 即 POC-2 G1 遗留缺口（poc-验证报告 §10：「deadline 到点唤醒 → cancel
  路径未验证」）的 v1 唤醒机制：以 Oban 周期扫描替代 Schedule Directive，链路测试见
  `test/cgc_2046/workers/approval_expiry_worker_test.exs`「POC-2 G1 补测」。

  D-A6 纪律：状态转换只走既有 Ash 领域 action（强一致路径），不发明第二条转换路径
  （不裸写 Ecto UPDATE）。扫描本身是读；两资源 multitenancy 均 `global?(true)`，
  跨租户读无需逐 tenant 迭代。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # 唯一窗与 cron 周期（5 分钟）对齐：防抖重复入队/手动重触造成的并发拍。
    # 拍内转换本身幂等（终态守卫），唯一任务是防并发双拍的第二层。
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  # `^ref(column)` 动态列引用（@expiry_specs 表驱动下推过滤用）
  import Ash.Expr, only: [ref: 1]

  alias Cgc2046.Accounts.Invitation
  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Accounts.WorkspaceApplication
  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Sponsorship.Sponsorship
  alias Cgc2046.Workflows.WorkflowRun

  # 六份过期扫描的声明式规格（PR-D）：每行 = 一个资源面。
  # - 列实体（deadline: {:column, atom}）：SQL 下推过滤（status + 列非空 + 列 < now），
  #   不退化为全表 load；列实体 deadline 列 nil 的永不扫中。
  # - WorkflowRun（deadline: :derived）：load definition + ApprovalDeadline.overdue?
  #   内存判断——唯一非列路径，绝不可并入纯 SQL 分支（timeout nil 的 run 靠
  #   overdue? 返回 false 永不扫中）。
  # - tenant 字段是各资源租户性质的声明；per-record 的 :expire 转换带/不带 tenant
  #   由下方 expire_record 子句按结构体原样处理（全局资源 update 不带 tenant）。
  @expiry_specs [
    # E-3 #48 F7：pending 报名超时 → expired。
    %{
      resource: Enrollment,
      status: :pending,
      deadline: {:column, :approval_deadline},
      tenant: true
    },
    # 决策 3：pending 加入申请超时 → expired。
    %{
      resource: JoinRequest,
      status: :pending,
      deadline: {:column, :approval_deadline},
      tenant: true
    },
    # E-3 #48 F7：pending 赞助超时 → expired（≠ rejected，可重提；重提走新行）。
    %{
      resource: Sponsorship,
      status: :pending,
      deadline: {:column, :approval_deadline},
      tenant: true
    },
    # WorkspaceApplication（accounts，全局资源）：pending + deadline 过点 → :expire。
    %{
      resource: WorkspaceApplication,
      status: :pending,
      deadline: {:column, :approval_deadline},
      tenant: false
    },
    # Invitation（accounts，租户资源，#114）：active + expires_at 过点 → :expire。
    # expires_at = nil（存量及 member 邀请默认）永不扫中；读时 effective_status 兜底不变。
    %{resource: Invitation, status: :active, deadline: {:column, :expires_at}, tenant: true},
    # WorkflowRun：waiting + 内存派生 deadline 过点（唯一 :derived 路径）。deadline =
    # run 进入 waiting 的时间（updated_at，waiting 迁移刷新）+ approval_timeout；
    # approval_timeout = nil → 无超时（F7 方案 A），永不扫中。
    %{resource: WorkflowRun, status: :waiting, deadline: :derived, tenant: true}
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    expired =
      Enum.map(@expiry_specs, fn spec ->
        {spec.resource, sweep(spec, now)}
      end)

    if Enum.any?(expired, fn {_resource, count} -> count > 0 end) do
      summary =
        expired
        |> Enum.map(fn {resource, count} -> "#{count} #{kind(resource)}(s)" end)
        |> Enum.join(", ")

      Logger.info("approval expiry sweep: #{summary} expired")
    end

    :ok
  end

  # 列实体：SQL 下推过滤（status + 列非空 + 列 < now），不退化为全表 load。
  defp sweep(%{resource: resource, status: status, deadline: {:column, column}}, now) do
    resource
    |> Ash.Query.filter(status == ^status and not is_nil(^ref(column)) and ^ref(column) < ^now)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn record, acc ->
      case expire_record(record) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  # :derived 路径（WorkflowRun）：load definition + ApprovalDeadline.overdue? 内存判断。
  # deadline 派生唯一真源 = ApprovalDeadline（updated_at + definition.approval_timeout，
  # nil = 永不过期）。
  defp sweep(%{resource: WorkflowRun, status: :waiting, deadline: :derived}, now) do
    WorkflowRun
    |> Ash.Query.filter(status == :waiting)
    |> Ash.Query.load(definition: [:approval_timeout])
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn run, acc ->
      if ApprovalDeadline.overdue?(run, now) do
        case expire_record(run) do
          :ok -> acc + 1
          :skip -> acc
        end
      else
        acc
      end
    end)
  end

  # 日志与 warning 的 kind 短名（JoinRequest → "join_request"，与收敛前字面量一致）
  defp kind(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()

  # 单个记录转换失败不中断整拍：并发终态变化（approve/reject/expire 先落库）会被
  # 各领域 action 的状态守卫拒绝，属预期竞态，记 warning 跳过即可。
  defp expire_record(%JoinRequest{} = join_request) do
    join_request
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: join_request.workspace_id, authorize?: false)
    |> handle_expire_result("join_request", join_request.id)
  end

  # WorkspaceApplication 是全局资源：update 不带 tenant（区别于上述租户资源）
  defp expire_record(%WorkspaceApplication{} = application) do
    application
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(authorize?: false)
    |> handle_expire_result("workspace_application", application.id)
  end

  # Invitation 是租户资源：update 带 tenant: workspace_id（同 JoinRequest）
  defp expire_record(%Invitation{} = invitation) do
    invitation
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: invitation.workspace_id, authorize?: false)
    |> handle_expire_result("invitation", invitation.id)
  end

  defp expire_record(%Enrollment{} = enrollment) do
    enrollment
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: enrollment.workspace_id, authorize?: false)
    |> handle_expire_result("enrollment", enrollment.id)
  end

  defp expire_record(%Sponsorship{} = sponsorship) do
    sponsorship
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: sponsorship.workspace_id, authorize?: false)
    |> handle_expire_result("sponsorship", sponsorship.id)
  end

  defp expire_record(%WorkflowRun{} = run) do
    run
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: run.workspace_id, authorize?: false)
    |> handle_expire_result("workflow_run", run.id)
  end

  defp handle_expire_result(result, kind, id) do
    case result do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("approval expiry: #{kind} #{id} expire skipped: #{inspect(error)}")
        :skip
    end
  end
end
