defmodule Cgc2046.Workers.ApprovalReminderWorker do
  @moduledoc """
  48h 审批提醒 job（0C；Oban cron 每小时一拍，见 config.exs）。

  F7 方案 A「deadline 前 48h 提醒审批人」的两条独立扫描：

  1. Enrollment 扫描（run-less 报名的单属主提醒路径）：`status=pending` 且
     `approval_deadline` 落在 (now, now+48h] 的报名，逐条经 NotificationService
     的 Oban 队列为工作台 Owner/Admin 异步发送 approval_reminder 提醒。入队 args
     含 recipient identity + enrollment_id + deadline，NotificationWorker 7 天
     args-unique 保证同一报名同一收件人不重复、不同报名/不同收件人不折叠。
  2. WorkflowRun 扫描：`waiting` 且 deadline
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

  alias Cgc2046.Accounts.{UserIdentity, WorkspaceMembership}
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Events.Sponsorship
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
      with deadline when not is_nil(deadline) <- approval_deadline(run),
           true <- in_window?(deadline, now, window_end),
           :remind <- maybe_log_run_reminder(run, deadline) do
        acc + 1
      else
        _ -> acc
      end
    end)
  end

  # run-less 报名的单属主提醒路径（语义与窗口见 moduledoc）。
  # 按 workspace 分组：成员名单与平台身份每工作台各读一次，与报名数解耦。
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
      identities_by_user = managed_identities_by_user(workspace_id)

      Enum.reduce(enrollments, 0, fn enrollment, acc ->
        Enum.reduce(identities_by_user, acc, fn {user_id, identities}, acc2 ->
          Cgc2046.NotificationSubscriber.enqueue_reminder_jobs(
            identities,
            user_id,
            enrollment.id,
            enrollment.approval_deadline
          )

          acc2 + length(identities)
        end)
      end)
    end)
    |> Enum.sum()
  end

  # E-3 #48 F7：赞助 48h 提醒。Event 级通知 Owner/Admin；Workspace 级仅 Owner
  # （拍板 #4）。入队 args 含 sponsorship_id + deadline（NotificationWorker
  # 7 天 args-unique 保证同一赞助同一收件人不重复）。
  defp remind_pending_sponsorships(now, window_end) do
    Sponsorship
    |> Ash.Query.filter(
      status == :pending and not is_nil(approval_deadline) and approval_deadline > ^now and
        approval_deadline <= ^window_end
    )
    |> Ash.Query.select([:id, :workspace_id, :event_id, :approval_deadline])
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.map(fn {workspace_id, sponsorships} ->
      identities_by_user = managed_identities_by_user(workspace_id, [:owner, :admin])
      owner_identities_by_user = managed_identities_by_user(workspace_id, [:owner])

      Enum.reduce(sponsorships, 0, fn sponsorship, acc ->
        recipients =
          if is_nil(sponsorship.event_id), do: owner_identities_by_user, else: identities_by_user

        Enum.reduce(recipients, acc, fn {user_id, identities}, acc2 ->
          Cgc2046.NotificationSubscriber.enqueue_sponsorship_reminder_jobs(
            identities,
            user_id,
            sponsorship.id,
            sponsorship.approval_deadline
          )

          acc2 + length(identities)
        end)
      end)
    end)
    |> Enum.sum()
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

  # role_filter 收窄收件人（赞助 Workspace 级 = 仅 Owner，拍板 #4）。
  defp managed_member_ids(workspace_id, role_filter) do
    WorkspaceMembership
    |> Ash.Query.load(:roles)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Enum.any?(&(&1 in role_filter))
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end

  # 每工作台一次身份读取，按 user_id 分组（消除 enrollment × 成员 的 N+1）。
  defp managed_identities_by_user(workspace_id, role_filter \\ [:owner, :admin]) do
    case managed_member_ids(workspace_id, role_filter) do
      [] ->
        %{}

      managed_ids ->
        UserIdentity
        |> Ash.Query.filter(user_id in ^managed_ids)
        |> Ash.read!(authorize?: false)
        |> Enum.group_by(& &1.user_id)
    end
  end
end
