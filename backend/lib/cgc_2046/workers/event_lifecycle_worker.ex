defmodule Cgc2046.Workers.EventLifecycleWorker do
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

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    closed_events = close_overdue(Event, now)
    closed_courses = close_overdue(Course, now)

    if closed_events + closed_courses > 0 do
      Logger.info(
        "event lifecycle sweep: closed #{closed_events} event(s), #{closed_courses} course(s)"
      )
    end

    :ok
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
end
