defmodule Cgc2046.Workers.ApprovalReminderWorker do
  @moduledoc """
  48h 审批提醒 job（0C；Oban cron 每小时一拍，见 config.exs）。

  F7 方案 A「deadline 前 48h 提醒审批人」的两条独立扫描：

  1. Enrollment 扫描（run-less 报名的单属主提醒路径）：`status=pending` 且
     `approval_deadline` 落在 (now, now+48h] 的报名，逐条经 NotificationService
     的 Oban 队列为工作台 Owner/Admin 异步发送 approval_reminder 提醒。入队 args
     含 recipient identity + enrollment_id + deadline，NotificationWorker 7 天
     args-unique 保证同一报名同一收件人不重复、不同报名/不同收件人不折叠。
  2. WorkflowRun 扫描（保留给非 Enrollment 的 waiting runs）：`waiting` 且 deadline
     （= run 进入 waiting 的 `updated_at` + definition.approval_timeout）落在未来
     48h 窗口内的 run，每 run 落一条 SignalLog（`signal_type=
     "workflow.approval_reminder"`）作为提醒事实记录。run 扫描不再反查 Enrollment
     发提醒——报名提醒由 Enrollment 扫描单属主承担，避免两条扫描 deadline 不同
     导致的重复提醒。

  幂等两层：
  1. Oban 唯一任务（同 args 1h 窗口内不重复入队，防 cron 抖动/手动重触的并发拍）；
  2. 入队侧 NotificationWorker 7 天全 args unique；落库侧 SignalLog 查重兜底
     （同 run 已有 approval_reminder 日志则跳过）。

  已过期（deadline < now）的不提醒——expiry worker 会把它们转 expired。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, WorkspaceMembership}
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowRun

  @reminder_window_hours 48
  @reminder_signal_type "workflow.approval_reminder"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    window_end = DateTime.add(now, @reminder_window_hours, :hour)

    reminded_runs = remind_waiting_runs(now, window_end)
    reminded_enrollments = remind_pending_enrollments(now, window_end)

    if reminded_runs + reminded_enrollments > 0 do
      Logger.info(
        "approval reminder sweep: #{reminded_runs} run(s), " <>
          "#{reminded_enrollments} enrollment(s) reminded"
      )
    end

    :ok
  end

  defp remind_waiting_runs(now, window_end) do
    WorkflowRun
    |> Ash.Query.filter(status == :waiting)
    |> Ash.Query.load(definition: [:approval_timeout])
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn run, acc ->
      with deadline when not is_nil(deadline) <- approval_deadline(run),
           true <- in_window?(deadline, now, window_end),
           :remind <- maybe_log_run_reminder(run, deadline) do
        acc + 1
      else
        _ -> acc
      end
    end)
  end

  # run-less 报名的单属主提醒路径：pending 且 approval_deadline ∈ (now, now+48h]。
  # 逐条为工作台 Owner/Admin 入队提醒；args 含 enrollment_id + deadline，
  # NotificationWorker 7 天 args-unique 去重。
  defp remind_pending_enrollments(now, window_end) do
    Enrollment
    |> Ash.Query.filter(
      status == :pending and not is_nil(approval_deadline) and approval_deadline > ^now and
        approval_deadline <= ^window_end
    )
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(enqueue_enrollment_reminder(&1) == :ok))
  end

  defp approval_deadline(run) do
    case run.definition.approval_timeout do
      nil -> nil
      timeout -> DateTime.add(run.updated_at, timeout, :second)
    end
  end

  # 窗口语义 (now, now+48h]：已过期的不提醒（expiry worker 负责转 expired），
  # 超 48h 的留给后续拍。
  defp in_window?(deadline, now, window_end) do
    DateTime.compare(deadline, now) == :gt and DateTime.compare(deadline, window_end) != :gt
  end

  defp maybe_log_run_reminder(run, deadline) do
    if reminder_logged?(run) do
      :skip
    else
      SignalLog
      |> Ash.Changeset.for_create(
        :create,
        %{
          run_id: run.id,
          signal_type: @reminder_signal_type,
          payload: %{
            "kind" => "approval_reminder_48h",
            "approval_deadline" => DateTime.to_iso8601(deadline)
          }
        },
        tenant: run.workspace_id
      )
      |> Ash.create(tenant: run.workspace_id, authorize?: false)
      |> case do
        {:ok, _} ->
          :remind

        {:error, error} ->
          Logger.warning("approval reminder: run #{run.id} log skipped: #{inspect(error)}")
          :skip
      end
    end
  end

  defp reminder_logged?(run) do
    SignalLog
    |> Ash.Query.filter(run_id == ^run.id and signal_type == ^@reminder_signal_type)
    |> Ash.exists?(authorize?: false)
  end

  defp enqueue_enrollment_reminder(%Enrollment{} = enrollment) do
    enrollment.workspace_id
    |> managed_member_ids()
    |> Enum.each(
      &Cgc2046.NotificationSubscriber.enqueue_reminder(
        &1,
        enrollment.id,
        enrollment.approval_deadline
      )
    )

    :ok
  end

  defp managed_member_ids(workspace_id) do
    WorkspaceMembership
    |> Ash.Query.load(:roles)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Enum.any?(&Role.manage_role?/1)
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end
end
