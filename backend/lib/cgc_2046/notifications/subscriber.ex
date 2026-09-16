defmodule Cgc2046.Notifications.Subscriber do
  @moduledoc """
  订阅 Enrollment 生命周期信号并为相关用户创建 Oban 通知任务（E-2 #47）。

  订阅的信号与通知对象：

  - `enrollment.approved` / `enrollment.rejected` → 报名学员本人（审批结果，既有路径）
  - `enrollment.submitted`（request 策略）→ 报名所属 workspace 的 Owner/Admin
    （有新的待审批报名；open/invite_only 提交即刻确认，无待审批语义，不通知）
  - `enrollment.completed`（open 直接确认或审批通过）→ 报名学员本人（报名成功）
    ＋ 同一条信号追加核销码通知（#546；Event 报名有码，course 无码不发）

  订阅骨架与 claim-first 幂等语义由 `Cgc2046.Workflows.SignalSubscriber` 统一
  持有（语义事实见其 moduledoc）；收件人解析与 Oban 入队收敛到
  `Cgc2046.Notifications.Fanout`（唯一实现，通知分发面深化 PR-C）——本模块退化为
  **纯订阅方**，无公共入队面（异步计划 Q4 backlog）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: [
      "enrollment.approved",
      "enrollment.rejected",
      "enrollment.submitted",
      "enrollment.completed"
    ],
    idempotency: :claim_first,
    consumer_key: "subscriber"

  require Ash.Query

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Offering

  @submitted_signal "enrollment.submitted"
  @completed_signal "enrollment.completed"

  # claim-first：claim 后即 at-most-once——Oban 入队失败则通知永久丢失（重投被 claim
  # 拦截），由 E-10 对账扫描 best-effort 兜底（#134-③）。
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

  # approved / rejected → 报名学员本人，逐平台身份入队（#3）。活动名称与名额
  # 序号（approval_result 模板 thing1/number3 数据源）经反查补齐——信号 payload
  # 只带基础键（enrollment.ex approval_payload），title 解析复用 Offering 读取面。
  defp handle_approval_result(%{"user_id" => user_id, "enrollment_id" => enrollment_id} = payload) do
    Cgc2046.Notifications.Fanout.deliver(
      {user_id, Cgc2046.Notifications.Fanout.identities(user_id)},
      "approval_result",
      Map.merge(
        %{
          "status" => payload["status"] || "processed",
          "enrollment_id" => enrollment_id
        },
        approval_context(enrollment_id)
      ),
      %{"enrollment_id" => enrollment_id}
    )
  end

  # 反查失败降级为缺字段发送（渲染层对 nil 跳过），不阻塞通知本身。
  defp approval_context(enrollment_id) do
    Enrollment
    |> Ash.Query.filter(id == ^enrollment_id)
    |> Ash.Query.select([:event_id, :course_id, :capacity_seq])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, enrollment} when not is_nil(enrollment) ->
        Map.merge(%{"capacity_seq" => enrollment.capacity_seq}, offering_title(enrollment))

      _ ->
        %{}
    end
  end

  defp offering_title(enrollment) do
    case Offering.fetch_by_signal_payload(%{
           "event_id" => enrollment.event_id,
           "course_id" => enrollment.course_id
         }) do
      {:ok, offering} -> %{"title" => Offering.title(offering)}
      {:error, _} -> %{}
    end
  end

  # 待审批报名 → workspace Owner/Admin（管理角色判定唯一真源
  # `Role.manage_roles/0`，经 Notifications.Fanout.managers/2 收敛）。
  defp notify_workspace_managers(data) do
    enrollment_id = Map.fetch!(data, "enrollment_id")
    job_meta = %{"enrollment_id" => enrollment_id, "idempotency_key" => producer_key(data)}

    with {:ok, title} <- target_title(data) do
      data
      |> Map.fetch!("workspace_id")
      |> Cgc2046.Notifications.Fanout.managers()
      |> Cgc2046.Notifications.Fanout.deliver(
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
  # #546：confirmed 就是「核销码已就绪」的时刻（码在 create 生成，Enrollment
  # KTD5），故同一信号再下发一条带码的通知；两条 job 的 args 因 template_key /
  # data 不同而互不折叠，共用同一 job_meta 幂等键即可（同一报名各发一次）。
  defp enqueue_completed(data) do
    enrollment_id = Map.fetch!(data, "enrollment_id")

    with {:ok, title} <- target_title(data),
         user_id when is_binary(user_id) <- Map.get(data, "user_id") do
      recipients = {user_id, Cgc2046.Notifications.Fanout.identities(user_id)}
      job_meta = %{"enrollment_id" => enrollment_id, "idempotency_key" => producer_key(data)}

      Cgc2046.Notifications.Fanout.deliver(
        recipients,
        "enrollment_completed",
        %{"enrollment_id" => enrollment_id, "title" => title},
        job_meta
      )

      enqueue_check_in_code(recipients, job_meta, enrollment_id, title, data)
    else
      {:error, reason} ->
        Logger.warning(
          "enrollment completed notification skipped for #{enrollment_id}: #{inspect(reason)}"
        )

      _ ->
        Logger.warning("enrollment completed notification skipped: missing user_id")
    end
  end

  # 核销码通知（#546）：反查报名取码，**无码 / 读失败一律不发**——「没有码的核销
  # 码通知」正是本 issue 要消除的失败形态。两条无码路径都被同一条判据覆盖：
  # course 报名恒 nil（Enrollment KTD5）、event 报名历史/异常行（回填漏网）。
  # 反查口径同 approval_context/1（通知侧自补数据，不动信号 payload 契约）。
  defp enqueue_check_in_code(recipients, job_meta, enrollment_id, title, data) do
    case check_in_code(enrollment_id, data) do
      {:ok, code} ->
        Cgc2046.Notifications.Fanout.deliver(
          recipients,
          "enrollment_check_in_code",
          %{"enrollment_id" => enrollment_id, "title" => title, "check_in_code" => code},
          job_meta
        )

      :skip ->
        :ok
    end
  end

  defp check_in_code(enrollment_id, _data) do
    case Ash.get(Enrollment, enrollment_id, authorize?: false) do
      {:ok, %{check_in_code: code}} when is_binary(code) and code != "" ->
        {:ok, code}

      {:ok, _missing_or_no_code} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "enrollment check-in code notification skipped for #{enrollment_id}: #{inspect(reason)}"
        )

        :skip
    end
  end

  # 任务身份锚用生产者注入的幂等键（SignalEmitter 保证存在，骨架 claim 前置门控）。
  defp producer_key(data), do: Map.fetch!(data, "idempotency_key")

  # 标题解析唯一真源 = Offering 读取面（fetch_by_signal_payload 按 event_id/course_id
  # 分派；错误坍缩 :not_found——原 :event_not_found/:course_not_found/:target_not_found
  # 仅进日志无消费方，D6 审计）。
  defp target_title(data) do
    with {:ok, offering} <- Cgc2046.Offering.fetch_by_signal_payload(data) do
      {:ok, Cgc2046.Offering.title(offering)}
    end
  end
end
