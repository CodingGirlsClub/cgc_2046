defmodule Cgc2046.Events.EventLifecycleWorker do
  @moduledoc """
  生命周期到点扫描（E-9 #124）：registration_deadline 过点的 open Event/Course
  → :close 动作转 closed（close 的 after_transaction 发 ended 信号）。

  v1 落地形态：Oban cron 周期扫描（复用 ApprovalExpiryWorker 模式），替代
  Schedule Directive 的 deadline 唤醒（报名 #5-② 同款消解：run 语义随实体
  自序贯消失，报名窗锁定由 close + Enrollment 的 SQL 守卫承担）。

  并发纪律同 ApprovalExpiryWorker：
  - Oban 唯一任务（300s 窗口，与 cron 周期对齐）防并发双拍；
  - 拍内转换幂等（close 状态守卫拒绝重复/竞态转换），单记录失败记 warning
    跳过不中断整拍（手动 close 先落库属预期竞态）。

  无成班判定且无报名截止的活动（min_participants 与 registration_deadline
  均 nil，押金场即属此类）在 ends_at 过点时关闭——这也是押金场进入 no-show
  结算的前提（DepositForfeitWorker 只结算 closed 场）。

  无截止场的成班判定兜底（#585 R2）：registration_deadline 未设的场以
  starts_at - 72h 为判定锚点（单源 `Qualification.effective_deadline/1`）；
  starts_at 也未设的场显式永不判定（接受语义，见该函数 doc）。
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Events.Qualification

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    {qualified_events, closed_events} = sweep_events(now)
    closed_courses = close_overdue(Course, now)

    if qualified_events + closed_events + closed_courses > 0 do
      Logger.info(
        "event lifecycle sweep: qualified #{qualified_events} event(s), closed #{closed_events} event(s), #{closed_courses} course(s)"
      )
    end

    :ok
  end

  # Event 的 deadline 语义分两支：未配置最小开班人数的旧活动仍在报名截止时
  # 结束；配置了阈值的活动在截止时只落一次 qualification 事实，成班活动保持
  # open 到 ends_at，未达活动转 cancelled 触发现有批量退款信号。
  defp sweep_events(now) do
    # 无截止场候选（#585 R2）：判定锚点 = starts_at - 72h（单源
    # Qualification.effective_deadline/1），候选按 starts_at < now + 72h 圈入
    # （⟺ starts_at - 72h < now）。deadline 未过的场也会混入候选，由下方 cond
    # 按 effective_deadline 精判后空转一行，可忽略。
    fallback_cutoff = DateTime.add(now, Qualification.fallback_window_hours(), :hour)

    events =
      Event
      |> Ash.Query.filter(
        status == :open and
          ((not is_nil(registration_deadline) and registration_deadline < ^now) or
             (not is_nil(ends_at) and ends_at < ^now) or
             (is_nil(registration_deadline) and not is_nil(starts_at) and
                starts_at < ^fallback_cutoff))
      )
      |> Ash.read!(authorize?: false)

    Enum.reduce(events, {0, 0}, fn event, {qualified, closed} ->
      deadline = Qualification.effective_deadline(event)

      cond do
        event.qualification_status == :underfilled && event.status == :open ->
          case cancel_record(event) do
            :ok -> {qualified, closed + 1}
            :skip -> {qualified, closed}
          end

        event.min_participants && event.qualification_status == :pending &&
          not is_nil(deadline) && DateTime.compare(deadline, now) == :lt ->
          case qualify_event(event) do
            {:ok, :underfilled, _enrollments, _count} ->
              case cancel_record(event) do
                :ok -> {qualified + 1, closed + 1}
                :skip -> {qualified + 1, closed}
              end

            {:ok, :confirmed, _enrollments, _count} ->
              {qualified + 1, closed}

            :skip ->
              {qualified, closed}
          end

        is_nil(event.min_participants) && event.registration_deadline &&
            DateTime.compare(event.registration_deadline, now) == :lt ->
          case close_record(event) do
            :ok -> {qualified, closed + 1}
            :skip -> {qualified, closed}
          end

        event.qualification_status == :confirmed && event.ends_at &&
            DateTime.compare(event.ends_at, now) == :lt ->
          case close_record(event) do
            :ok -> {qualified, closed + 1}
            :skip -> {qualified, closed}
          end

        is_nil(event.min_participants) && is_nil(event.registration_deadline) &&
          event.ends_at && DateTime.compare(event.ends_at, now) == :lt ->
          case close_record(event) do
            :ok -> {qualified, closed + 1}
            :skip -> {qualified, closed}
          end

        true ->
          {qualified, closed}
      end
    end)
  end

  defp qualify_event(event) do
    Qualification.qualify(event)
  end

  # registration_deadline = nil（无截止）永不在此扫中（同 Invitation expires_at
  # 语义；仅指 Course 关闭面——Event 成班判定的无截止兜底见 sweep_events 的
  # starts_at 支）。
  defp close_overdue(resource, now) do
    resource
    |> Ash.Query.filter(
      status == :open and not is_nil(registration_deadline) and registration_deadline < ^now
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn entity, acc ->
      case close_record(entity) do
        :ok -> acc + 1
        :skip -> acc
      end
    end)
  end

  # 单个记录转换失败不中断整拍：并发手动 close/状态变化会被 close 的状态守卫
  # 拒绝，属预期竞态，记 warning 跳过。
  defp close_record(entity) do
    case entity
         |> Ash.Changeset.for_update(:close, %{}, tenant: entity.workspace_id, authorize?: false)
         |> Ash.update(tenant: entity.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "event lifecycle close failed for #{entity.__struct__} #{entity.id}: #{inspect(reason)}"
        )

        :skip
    end
  end

  defp cancel_record(entity) do
    case entity
         |> Ash.Changeset.for_update(:cancel, %{}, tenant: entity.workspace_id, authorize?: false)
         |> Ash.update(tenant: entity.workspace_id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("event lifecycle cancel failed for #{entity.id}: #{inspect(reason)}")
        :skip
    end
  end
end
