defmodule Cgc2046.NotificationSubscriber do
  @moduledoc """
  订阅 Enrollment 生命周期信号并为相关用户创建 Oban 通知任务（E-2 #47）。

  订阅的信号与通知对象：

  - `enrollment.approved` / `enrollment.rejected` → 报名学员本人（审批结果，既有路径）
  - `enrollment.submitted`（request 策略）→ 报名所属 workspace 的 Owner/Admin
    （有新的待审批报名；open/invite_only 提交即刻确认，无待审批语义，不通知）
  - `enrollment.completed`（open 直接确认或审批通过）→ 报名学员本人（报名成功）

  订阅骨架与 claim-first 幂等语义由 `Cgc2046.Workflows.SignalSubscriber` 统一
  持有（语义事实见其 moduledoc）；收件人解析与 Oban 入队收敛到
  `Cgc2046.NotificationFanout`（唯一实现，通知分发面深化 PR-C）——本模块退化为
  **纯订阅方**，无公共入队面（异步计划 Q4 backlog）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: [
      "enrollment.approved",
      "enrollment.rejected",
      "enrollment.submitted",
      "enrollment.completed"
    ],
    idempotency: :claim_first

  require Logger

  alias Cgc2046.Events.{Course, Event}

  @submitted_signal "enrollment.submitted"
  @completed_signal "enrollment.completed"

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(@submitted_signal, data), do: handle_submitted(data)
  def handle(@completed_signal, data), do: handle_completed(data)

  # approved / rejected → 审批结果通知（既有路径）
  def handle(_type, data), do: handle_approval_result(data)

  # submitted：request 策略才有「待审批」语义；open/invite_only 提交即确认，不通知。
  defp handle_submitted(data) do
    case data do
      %{"enrollment_policy" => "request", "enrollment_id" => id} when is_binary(id) ->
        notify_workspace_managers(data)

      _ ->
        :ok
    end
  end

  defp handle_completed(data) do
    case Map.get(data, "enrollment_id") do
      id when is_binary(id) ->
        enqueue_completed(data)

      _ ->
        :ok
    end
  end

  # approved / rejected → 报名学员本人，逐平台身份入队（#3）。
  defp handle_approval_result(%{"user_id" => user_id, "enrollment_id" => enrollment_id} = payload) do
    Cgc2046.NotificationFanout.deliver(
      {user_id, Cgc2046.NotificationFanout.identities(user_id)},
      "approval_result",
      %{
        "status" => payload["status"] || "processed",
        "enrollment_id" => enrollment_id
      },
      %{"enrollment_id" => enrollment_id}
    )
  end

  # 待审批报名 → workspace Owner/Admin（管理角色判定唯一真源
  # `Role.manage_roles/0`，经 NotificationFanout.managers/2 收敛）。
  defp notify_workspace_managers(data) do
    enrollment_id = Map.fetch!(data, "enrollment_id")
    job_meta = %{"enrollment_id" => enrollment_id, "idempotency_key" => producer_key(data)}

    with {:ok, title} <- target_title(data) do
      data
      |> Map.fetch!("workspace_id")
      |> Cgc2046.NotificationFanout.managers()
      |> Cgc2046.NotificationFanout.deliver(
        "enrollment_submitted",
        %{"enrollment_id" => enrollment_id, "title" => title},
        job_meta
      )
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
  defp enqueue_completed(data) do
    enrollment_id = Map.fetch!(data, "enrollment_id")

    with {:ok, title} <- target_title(data),
         user_id when is_binary(user_id) <- Map.get(data, "user_id") do
      Cgc2046.NotificationFanout.deliver(
        {user_id, Cgc2046.NotificationFanout.identities(user_id)},
        "enrollment_completed",
        %{"enrollment_id" => enrollment_id, "title" => title},
        %{"enrollment_id" => enrollment_id, "idempotency_key" => producer_key(data)}
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

  # 任务身份锚用生产者注入的幂等键（SignalEmitter 保证存在，骨架 claim 前置门控）。
  defp producer_key(data), do: Map.fetch!(data, "idempotency_key")

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
end
