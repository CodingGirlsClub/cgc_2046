defmodule Cgc2046.NotificationSubscriber do
  @moduledoc """
  订阅 Enrollment 生命周期信号并为相关用户创建 Oban 通知任务（E-2 #47）。

  订阅的信号与通知对象：

  - `enrollment.approved` / `enrollment.rejected` → 报名学员本人（审批结果，既有路径）
  - `enrollment.submitted`（request 策略）→ 报名所属 workspace 的 Owner/Admin
    （有新的待审批报名；open/invite_only 提交即刻确认，无待审批语义，不通知）
  - `enrollment.completed`（open 直接确认或审批通过）→ 报名学员本人（报名成功）

  幂等两层（对齐 approval_reminder 模式）：

  1. 订阅方执行任何副作用前先 `SignalIdempotency.claim/3`（`(signal_type,
     idempotency_key)` 唯一索引兜底，并发登记至多一行成功）；claim 返回
     `{:error, :already_claimed}`（已消费）→ 跳过执行并返回 `:duplicate`；
  2. 入队侧 NotificationWorker 7 天全 args unique，同一信号重复入队被折叠。
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{Role, UserIdentity, WorkspaceMembership}
  alias Cgc2046.Events.{Course, Event}
  alias Cgc2046.Workflows.{JidoAdapter, SignalIdempotency}
  alias Cgc2046.Workers.NotificationWorker

  @patterns [
    "enrollment.approved",
    "enrollment.rejected",
    "enrollment.submitted",
    "enrollment.completed"
  ]

  @submitted_signal "enrollment.submitted"
  @completed_signal "enrollment.completed"

  @doc "当前订阅的信号类型列表（init 逐个订阅；测试断言接线用）。"
  def patterns, do: @patterns

  # 提醒任务的去重窗口：discarded/cancelled 释放名额（失败后下拍可重建），
  # completed/在途仍阻塞重复（#7）。
  @reminder_unique [
    period: 604_800,
    fields: [:worker, :args],
    states: [:scheduled, :available, :executing, :retryable, :completed]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Enum.each(@patterns, fn pattern ->
      case JidoAdapter.subscribe(pattern, &handle_signal/1, nil) do
        {:ok, _subscription} -> :ok
        {:error, reason} -> Logger.warning("notification subscribe failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{}}
  end

  def enqueue_approval_result(%{"user_id" => user_id, "enrollment_id" => enrollment_id} = payload) do
    enqueue_for_identities(
      user_id,
      "approval_result",
      %{
        "status" => payload["status"] || "processed",
        "enrollment_id" => enrollment_id
      },
      %{"enrollment_id" => enrollment_id}
    )
  end

  def enqueue_reminder(user_id, enrollment_id, deadline) do
    user_id
    |> identities_for_user()
    |> enqueue_reminder_jobs(user_id, enrollment_id, deadline)
  rescue
    error ->
      Logger.warning("approval reminder enqueue failed: #{Exception.message(error)}")
      :ok
  end

  @doc "批量入口：调用方已预取该用户的平台身份（如按 workspace 一次读出）。"
  def enqueue_reminder_jobs(identities, user_id, enrollment_id, deadline) do
    Enum.each(identities, fn identity ->
      insert_notification(
        identity,
        user_id,
        "approval_reminder",
        %{
          "enrollment_id" => enrollment_id,
          "approval_deadline" => DateTime.to_iso8601(deadline)
        },
        %{"enrollment_id" => enrollment_id},
        @reminder_unique
      )
    end)

    :ok
  rescue
    error ->
      Logger.warning("approval reminder enqueue failed: #{Exception.message(error)}")
      :ok
  end

  defp enqueue_for_identities(user_id, template_key, data, job_meta) do
    user_id
    |> identities_for_user()
    |> Enum.each(&insert_notification(&1, user_id, template_key, data, job_meta, nil))

    :ok
  rescue
    error ->
      Logger.warning("approval notification enqueue failed: #{Exception.message(error)}")
      :ok
  end

  defp identities_for_user(user_id) do
    UserIdentity
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  # args 携带 identity_uid：同用户同平台多身份不再被 args-unique 折叠，
  # 发送侧按该身份精确投递（#3）。
  defp insert_notification(identity, user_id, template_key, data, job_meta, unique_override) do
    args =
      job_meta
      |> Map.merge(%{
        "user_id" => user_id,
        "identity_uid" => identity.uid,
        "platform" => to_string(identity.provider),
        "template_key" => template_key,
        "data" => data
      })

    case unique_override do
      nil -> NotificationWorker.new(args)
      unique -> NotificationWorker.new(args, unique: unique)
    end
    |> Oban.insert!()
  end

  @doc """
  信号总线回调：按 `signal.type` 分流到对应通知路径。

  回调运行在 JidoAdapter 转发的独立进程中（spawn_link），rescue 兜底防订阅
  进程崩溃。重复投递（同 idempotency_key 已 claim）返回 `:duplicate` 并跳过。
  """
  def handle_signal(signal) do
    data = Map.get(signal, :data) || %{}

    case Map.get(signal, :type) do
      @submitted_signal -> handle_submitted(data)
      @completed_signal -> handle_completed(data)
      _ -> enqueue_approval_result(data)
    end
  rescue
    error ->
      Logger.warning("notification signal handling failed: #{Exception.message(error)}")
      :ok
  end

  # submitted：request 策略才有「待审批」语义；open/invite_only 提交即确认，不通知。
  defp handle_submitted(data) do
    case data do
      %{"enrollment_policy" => "request", "enrollment_id" => id} when is_binary(id) ->
        with {:ok, key} <- claim(@submitted_signal, id, data) do
          notify_workspace_managers(data, key)
        end

      _ ->
        :ok
    end
  end

  defp handle_completed(data) do
    case Map.get(data, "enrollment_id") do
      id when is_binary(id) ->
        with {:ok, key} <- claim(@completed_signal, id, data) do
          enqueue_completed(data, key)
        end

      _ ->
        :ok
    end
  end

  # 副作用前幂等登记：首次 claim 返回 {:ok, key}；同 (signal_type, idempotency_key)
  # 已消费返回 :duplicate（调用方跳过）。key 优先取生产者携带的 idempotency_key
  # （completed），否则按 <signal_type>:<enrollment_id> 派生（submitted）。
  defp claim(signal_type, enrollment_id, data) do
    key = Map.get(data, "idempotency_key") || "#{signal_type}:#{enrollment_id}"

    case SignalIdempotency.claim(signal_type, key, Map.get(data, "workspace_id")) do
      :ok -> {:ok, key}
      {:error, :already_claimed} -> :duplicate
    end
  end

  # 待审批报名 → workspace Owner/Admin（管理角色判定与 ApprovalReminderWorker 同款）。
  defp notify_workspace_managers(data, key) do
    enrollment_id = Map.fetch!(data, "enrollment_id")
    job_meta = %{"enrollment_id" => enrollment_id, "idempotency_key" => key}

    with {:ok, title} <- target_title(data) do
      data
      |> Map.fetch!("workspace_id")
      |> managed_identities_by_user()
      |> Enum.each(fn {user_id, identities} ->
        Enum.each(identities, fn identity ->
          insert_notification(
            identity,
            user_id,
            "enrollment_submitted",
            %{"enrollment_id" => enrollment_id, "title" => title},
            job_meta,
            nil
          )
        end)
      end)
    else
      {:error, reason} ->
        Logger.warning(
          "enrollment submitted notification skipped for #{enrollment_id}: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    error ->
      Logger.warning("enrollment submitted notification failed: #{Exception.message(error)}")
      :ok
  end

  # 报名成功 → 报名学员本人（7 天 args-unique 走 NotificationWorker 默认 unique）。
  defp enqueue_completed(data, key) do
    enrollment_id = Map.fetch!(data, "enrollment_id")

    with {:ok, title} <- target_title(data),
         user_id when is_binary(user_id) <- Map.get(data, "user_id") do
      enqueue_for_identities(
        user_id,
        "enrollment_completed",
        %{"enrollment_id" => enrollment_id, "title" => title},
        %{"enrollment_id" => enrollment_id, "idempotency_key" => key}
      )
    else
      {:error, reason} ->
        Logger.warning(
          "enrollment completed notification skipped for #{enrollment_id}: #{inspect(reason)}"
        )

      _ ->
        Logger.warning("enrollment completed notification skipped: missing user_id")
    end
  end

  defp target_title(%{"event_id" => id}) when is_binary(id) and id != "" do
    case Ash.get(Event, id, authorize?: false) do
      {:ok, %Event{title: title}} -> {:ok, title}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_title(%{"course_id" => id}) when is_binary(id) and id != "" do
    case Ash.get(Course, id, authorize?: false) do
      {:ok, %Course{title: title}} -> {:ok, title}
      {:ok, nil} -> {:error, :course_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_title(_data), do: {:error, :target_not_found}

  # workspace Owner/Admin 的平台身份（按 user_id 分组；每工作台一次读取，
  # 与 ApprovalReminderWorker.managed_identities_by_user 同款实现）。
  defp managed_identities_by_user(workspace_id) do
    managed_ids =
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

    case managed_ids do
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
