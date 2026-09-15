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
    events =
      Event
      |> Ash.Query.filter(
        status == :open and
          ((not is_nil(registration_deadline) and registration_deadline < ^now) or
             (not is_nil(ends_at) and ends_at < ^now))
      )
      |> Ash.read!(authorize?: false)

    Enum.reduce(events, {0, 0}, fn event, {qualified, closed} ->
      cond do
        event.qualification_status == :underfilled && event.status == :open ->
          case cancel_record(event) do
            :ok -> {qualified, closed + 1}
            :skip -> {qualified, closed}
          end

        event.min_participants && event.qualification_status == :pending &&
          event.registration_deadline && DateTime.compare(event.registration_deadline, now) == :lt ->
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

        true ->
          {qualified, closed}
      end
    end)
  end

  defp qualify_event(event) do
    Qualification.qualify(event)
  end

  # registration_deadline = nil（无截止）永不扫中（同 Invitation expires_at 语义）。
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
