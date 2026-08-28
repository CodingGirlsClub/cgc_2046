defmodule Cgc2046.Events.CapacityProjectionSubscriber do
  @moduledoc """
  Event 侧 `confirmed_count` 展示投影订阅器（ADR-0009 PR⑤ U7；R15；KD2/KTD4）。

  订阅 Admission 在账本写成功后同事务发布的 `capacity.synced`（载荷 =
  CAS RETURNING 的权威 `occupancy` + 单调 `sync_version`），自写本表
  `confirmed_count` 列——Events 写 events 表是自写，不构成跨 context 写点
  （KTD4；反向直写禁止）。course 载荷由
  `Cgc2046.Courses.CapacityProjectionSubscriber` 对称处理。

  覆盖式幂等 + 乱序收敛：条件 UPDATE `confirmed_count_sync_version < 新版本`
  才落写——同信号重投不改结果，旧版本不覆盖新值；0 行命中（乱序旧版本 /
  未知实体）归一 `:ok`。幂等策略 `:state_based`（CapacityLedgerSubscriber
  同款），骨架由 `Cgc2046.Workflows.SignalSubscriber` 统一持有。

  漂移兜底：E-10 对账规⑩ `:capacity_projection_drift`（投影滞后账本超一拍
  即出 finding，信号重投/恢复后自动消除）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["capacity.synced"],
    idempotency: :state_based,
    consumer_key: "capacity_projection_subscriber"

  require Logger

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle("capacity.synced", %{"event_id" => event_id} = data)
      when is_binary(event_id) do
    apply_projection(event_id, data["occupancy"], data["sync_version"])
  end

  # course 载荷（或缺键）非本 context 职责：归一 :ok 不告警
  def handle("capacity.synced", _data), do: :ok

  defp apply_projection(event_id, occupancy, sync_version)
       when is_integer(occupancy) and is_integer(sync_version) do
    case Cgc2046.Repo.query(
           """
           UPDATE events
           SET confirmed_count = $1, confirmed_count_sync_version = $2, updated_at = NOW()
           WHERE id = $3 AND confirmed_count_sync_version < $2
           """,
           [occupancy, sync_version, Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Events.CapacityProjectionSubscriber apply failed for event #{event_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # 载荷缺 occupancy/sync_version = 生产者契约违约：不崩 forwarder，记 error 丢弃
  defp apply_projection(event_id, occupancy, sync_version) do
    Logger.error(
      "Events.CapacityProjectionSubscriber malformed capacity.synced for event #{event_id}: " <>
        "occupancy=#{inspect(occupancy)} sync_version=#{inspect(sync_version)}"
    )

    :ok
  end
end
