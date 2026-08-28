defmodule Cgc2046.Workers.ApprovalReminderWorker do
  @moduledoc """
  48h 审批提醒 job（0C；Oban cron 每小时一拍，见 config.exs）。

  F7 方案 A「deadline 前 48h 提醒审批人」的三条独立扫描：

  1. Enrollment 扫描（run-less 报名的单属主提醒路径）：`status=pending` 且
     `approval_deadline` 落在 (now, now+48h] 的报名，逐条经 NotificationService
     的 Oban 队列为工作台 Owner/Admin 异步发送 approval_reminder 提醒。入队 args
     含 recipient identity + enrollment_id + deadline，NotificationWorker 7 天
     args-unique 保证同一报名同一收件人不重复、不同报名/不同收件人不折叠。
  2. Sponsorship 扫描（E-3 #48 F7）：`status=pending` 且 deadline 落在 48h
     窗口内的赞助，为审批人入队 approval_reminder 提醒（data 携带
     sponsorship_id）——Event 级提醒 Owner/Admin、Workspace 级仅提醒 Owner
     （拍板 #4）。
  3. WorkflowRun 扫描：`waiting` 且 deadline
     （= run 进入 waiting 的 `updated_at` + definition.approval_timeout）落在未来
     48h 窗口内的 run，每 run 落一条 SignalLog（`signal_type=
     "workflow.approval_reminder"`）——该行仅为**审计事实记录**，对**所有** waiting
     run 落行（含关联 Enrollment 的 run），不触发通知。run 扫描不再反查 Enrollment
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

  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Events.Sponsorship
  alias Cgc2046.Policies.SponsorshipApprover
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowRun

  @reminder_window_hours 48
  @reminder_signal_type "workflow.approval_reminder"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    window_end = DateTime.add(now, @reminder_window_hours, :hour)

    reminded_runs = remind_waiting_runs(now, window_end)

    enqueued_notifications =
      remind_pending_enrollments(now, window_end) + remind_pending_sponsorships(now, window_end)

    if reminded_runs + enqueued_notifications > 0 do
      Logger.info(
        "approval reminder sweep: #{reminded_runs} run log(s), " <>
          "#{enqueued_notifications} notification(s) enqueued"
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
      with deadline when not is_nil(deadline) <- ApprovalDeadline.derive(run),
           true <- ApprovalDeadline.in_window?(deadline, now, window_end),
           :remind <- maybe_log_run_reminder(run, deadline) do
        acc + 1
      else
        _ -> acc
      end
    end)
  end

  # run-less 报名的单属主提醒路径（语义与窗口见 moduledoc）。
  # 按 workspace 分组：收件人（成员名单 + 平台身份）每工作台预取一次、逐条
  # enrollment 复用（消 N+1 的形状保持不变，通知分发面收敛 PR-C）。
  # 计数为实际入队的通知数（无平台身份的成员不计入）。
  defp remind_pending_enrollments(now, window_end) do
    Enrollment
    |> Ash.Query.filter(
      status == :pending and not is_nil(approval_deadline) and approval_deadline > ^now and
        approval_deadline <= ^window_end
    )
    |> Ash.Query.select([:id, :workspace_id, :approval_deadline])
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.map(fn {workspace_id, enrollments} ->
      recipients = Cgc2046.NotificationFanout.managers(workspace_id)

      Enum.reduce(enrollments, 0, fn enrollment, acc ->
        Cgc2046.NotificationFanout.deliver(
          recipients,
          "approval_reminder",
          %{
            "enrollment_id" => enrollment.id,
            "approval_deadline" => DateTime.to_iso8601(enrollment.approval_deadline)
          },
          %{"enrollment_id" => enrollment.id}
        )

        acc + recipient_count(recipients)
      end)
    end)
    |> Enum.sum()
  end

  # E-3 #48 F7：赞助 48h 提醒。Event 级通知 Owner/Admin；Workspace 级仅 Owner
  # （拍板 #4，规则唯一真源 `SponsorshipApprover.approver_roles/1`——两套收件人
  # 选择器按 `{:roles, approver_roles(level)}` 派生，与写面/读面同源）。入队 args
  # 含 sponsorship_id + deadline（NotificationWorker 7 天 args-unique 保证同一
  # 赞助同一收件人不重复）。
  defp remind_pending_sponsorships(now, window_end) do
    Sponsorship
    |> Ash.Query.filter(
      status == :pending and not is_nil(approval_deadline) and approval_deadline > ^now and
        approval_deadline <= ^window_end
    )
    |> Ash.Query.select([:id, :workspace_id, :event_id, :level, :approval_deadline])
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.map(fn {workspace_id, sponsorships} ->
      event_recipients =
        Cgc2046.NotificationFanout.managers(
          workspace_id,
          {:roles, SponsorshipApprover.approver_roles(:event)}
        )

      workspace_recipients =
        Cgc2046.NotificationFanout.managers(
          workspace_id,
          {:roles, SponsorshipApprover.approver_roles(:workspace)}
        )

      Enum.reduce(sponsorships, 0, fn sponsorship, acc ->
        recipients =
          if sponsorship.level == :workspace, do: workspace_recipients, else: event_recipients

        Cgc2046.NotificationFanout.deliver(
          recipients,
          "approval_reminder",
          %{
            "sponsorship_id" => sponsorship.id,
            "approval_deadline" => DateTime.to_iso8601(sponsorship.approval_deadline)
          },
          %{"sponsorship_id" => sponsorship.id}
        )

        acc + recipient_count(recipients)
      end)
    end)
    |> Enum.sum()
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

  # 计数语义与收敛前一致：每 (user_id × identity) 一条通知（无平台身份的
  # 成员不计入）。
  defp recipient_count(recipients) do
    Enum.reduce(recipients, 0, fn {_user_id, identities}, acc -> acc + length(identities) end)
  end
end
