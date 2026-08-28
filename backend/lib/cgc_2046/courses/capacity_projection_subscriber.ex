defmodule Cgc2046.Courses.CapacityProjectionSubscriber do
  @moduledoc """
  Course 侧 `confirmed_count` 展示投影订阅器（ADR-0009 PR⑤ U7；R15；KD2/KTD4）。

  与 `Cgc2046.Events.CapacityProjectionSubscriber` 同构对称：订阅
  `capacity.synced`，按 `course_id` 载荷自写 courses 表 `confirmed_count` 列，
  条件 `confirmed_count_sync_version < 新版本`（覆盖式幂等 + 乱序收敛）。
  event 载荷归 Events 侧订阅方，本模块归一 `:ok`。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["capacity.synced"],
    idempotency: :state_based

  require Logger

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle("capacity.synced", %{"course_id" => course_id} = data)
      when is_binary(course_id) do
    apply_projection(course_id, data["occupancy"], data["sync_version"])
  end

  # event 载荷（或缺键）非本 context 职责：归一 :ok 不告警
  def handle("capacity.synced", _data), do: :ok

  defp apply_projection(course_id, occupancy, sync_version)
       when is_integer(occupancy) and is_integer(sync_version) do
    case Cgc2046.Repo.query(
           """
           UPDATE courses
           SET confirmed_count = $1, confirmed_count_sync_version = $2, updated_at = NOW()
           WHERE id = $3 AND confirmed_count_sync_version < $2
           """,
           [occupancy, sync_version, Cgc2046.Repo.uuid!(course_id)]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Courses.CapacityProjectionSubscriber apply failed for course #{course_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # 载荷缺 occupancy/sync_version = 生产者契约违约：不崩 forwarder，记 error 丢弃
  defp apply_projection(course_id, occupancy, sync_version) do
    Logger.error(
      "Courses.CapacityProjectionSubscriber malformed capacity.synced for course #{course_id}: " <>
        "occupancy=#{inspect(occupancy)} sync_version=#{inspect(sync_version)}"
    )

    :ok
  end
end
