defmodule Cgc2046.Workers.ApprovalExpiryWorker do
  @moduledoc """
  审批超时扫描 worker（0C；Oban cron 每 5 分钟一拍，见 config.exs）。

  把「读时惰性计算过期」升级为「主动落库过期」，覆盖两类既有审批实体
  （Enrollment 尚未建模，Phase 2 接入时复用本 worker 同一扫描模式）：

  1. `JoinRequest`（accounts）：`status=pending 且 approval_deadline 已过` → 走既有
     `:expire` 领域 action 转 expired。落地 join_request.ex 的 TODO：「引入
     Quantum/Oban 定时器后改为主动转换，惰性计算作为兜底」（前端 ApprovalChip 的
     读时计算继续作为兜底，不受影响）。
  2. `WorkflowRun`（workflows）：F7 方案 A——`status=waiting 且 definition
     .approval_timeout 过点` → 走既有 `:expire` 领域 action（waiting → expired，
     含 checkpoint 终态清理）。deadline = run 进入 waiting 的时间（`updated_at`，
     每次 waiting 迁移刷新，重进 waiting 重新计窗）+ approval_timeout；
     `approval_timeout = nil` = 无超时，永不扫中。pending（未进入审批等待）不扫。

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

  alias Cgc2046.Accounts.JoinRequest
  alias Cgc2046.Workflows.WorkflowRun

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    expired_join_requests = expire_join_requests(now)
    expired_runs = expire_waiting_runs(now)

    if expired_join_requests + expired_runs > 0 do
      Logger.info(
        "approval expiry sweep: #{expired_join_requests} join_request(s), " <>
          "#{expired_runs} workflow_run(s) expired"
      )
    end

    :ok
  end

  defp expire_join_requests(now) do
    JoinRequest
    |> Ash.Query.filter(
      status == :pending and not is_nil(approval_deadline) and approval_deadline < ^now
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn join_request, acc ->
      case expire_record(join_request) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  defp expire_waiting_runs(now) do
    WorkflowRun
    |> Ash.Query.filter(status == :waiting)
    |> Ash.Query.load(definition: [:approval_timeout])
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn run, acc ->
      if approval_overdue?(run, now) do
        case expire_record(run) do
          :ok -> acc + 1
          :skip -> acc
        end
      else
        acc
      end
    end)
  end

  # deadline = run 进入 waiting 的时间（updated_at，waiting 迁移刷新）+ approval_timeout。
  # approval_timeout = nil → 无超时（F7 方案 A），永不扫中。
  defp approval_overdue?(%WorkflowRun{} = run, now) do
    case run.definition.approval_timeout do
      nil ->
        false

      timeout ->
        DateTime.compare(DateTime.add(run.updated_at, timeout, :second), now) == :lt
    end
  end

  # 单个记录转换失败不中断整拍：并发终态变化（approve/reject/expire 先落库）会被
  # 各领域 action 的状态守卫拒绝，属预期竞态，记 warning 跳过即可。
  defp expire_record(%JoinRequest{} = join_request) do
    join_request
    |> Ash.Changeset.for_update(:expire, %{})
    |> Ash.update(tenant: join_request.workspace_id, authorize?: false)
    |> handle_expire_result("join_request", join_request.id)
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
