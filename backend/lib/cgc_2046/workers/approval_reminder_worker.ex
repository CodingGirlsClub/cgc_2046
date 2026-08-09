defmodule Cgc2046.Workers.ApprovalReminderWorker do
  @moduledoc """
  48h 审批提醒 job 骨架（0C；Oban cron 每小时一拍，见 config.exs）。

  F7 方案 A「deadline 前 48h 提醒审批人」的 v1 骨架：扫描 `waiting` 且 deadline
  （= run 进入 waiting 的 `updated_at` + definition.approval_timeout）落在未来 48h
  窗口内的 WorkflowRun，每 run 落一条 SignalLog（`signal_type=
  "workflow.approval_reminder"`）作为提醒事实记录；若 run 关联 pending Enrollment，
  同时经 NotificationService 的 Oban 队列异步发送订阅消息。

  幂等两层：
  1. Oban 唯一任务（同 args 1h 窗口内不重复入队，防 cron 抖动/手动重触的并发拍）；
  2. 落库前查重：同 run 已有 approval_reminder 日志则跳过——一 run 一 waiting 周期
     只提醒一次。骨架语义：run 放行后重进 waiting 会复用旧日志不再提醒；Phase 2 接
     NotificationService 时按 gate/step 细化去重键。

  已过期（deadline < now）的不提醒——expiry worker 会把它们转 expired。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.WorkspaceMembership
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Rbac
  alias Cgc2046.Workflows.SignalLog
  alias Cgc2046.Workflows.WorkflowRun

  @reminder_window_hours 48
  @reminder_signal_type "workflow.approval_reminder"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    window_end = DateTime.add(now, @reminder_window_hours, :hour)

    reminded =
      WorkflowRun
      |> Ash.Query.filter(status == :waiting)
      |> Ash.Query.load(definition: [:approval_timeout])
      |> Ash.read!(authorize?: false)
      |> Enum.reduce(0, fn run, acc ->
        with deadline when not is_nil(deadline) <- approval_deadline(run),
             true <- in_window?(deadline, now, window_end),
             :remind <- maybe_remind(run, deadline) do
          acc + 1
        else
          _ -> acc
        end
      end)

    if reminded > 0 do
      Logger.info("approval reminder sweep: #{reminded} reminder(s) logged")
    end

    :ok
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

  defp maybe_remind(run, deadline) do
    if reminder_logged?(run) do
      # 首次落日志后若入队瞬时失败，下一拍可安全重试；NotificationWorker 按完整 args
      # 七天去重，已成功入队时不会产生重复通知。
      enqueue_enrollment_reminder(run, deadline)
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
          enqueue_enrollment_reminder(run, deadline)
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

  defp enqueue_enrollment_reminder(run, deadline) do
    Enrollment
    |> Ash.Query.filter(workflow_run_id == ^run.id and status == :pending)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Enrollment{workspace_id: workspace_id}} ->
        workspace_id
        |> managed_member_ids()
        |> Enum.each(&Cgc2046.NotificationSubscriber.enqueue_reminder(&1, deadline))

        :ok

      _ ->
        :ok
    end
  end

  defp managed_member_ids(workspace_id) do
    WorkspaceMembership
    |> Ash.Query.load(:roles)
    |> Ash.read!(tenant: workspace_id, authorize?: false)
    |> Enum.filter(fn membership ->
      membership.roles
      |> Enum.map(& &1.name)
      |> Rbac.roles_can?(:manage_members)
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end
end
