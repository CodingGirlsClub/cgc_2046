defmodule Cgc2046.Notifications.Staleness do
  @moduledoc """
  发送时的过期重查（表驱动单解释器，两条投递路径共用）。

  入队到发送之间业务状态可能已变（审批已处理、deadline 已过、learning run
  已终态），命中即不再发送。规格唯一真源是 `NotificationWorker` 的
  `@notification_types` registry（`types/0` 公开面）：template_key 定位 stale
  规格（`approval_reminder` 同键两行由 data 携带的 id_key 分派），nil = 不重查
  直接投递。本模块是该 registry stale 规格的唯一解释器——NotificationWorker
  与 DeliveryWorker 对同一 template_key 的过期判断由此保证完全一致（#847
  PR-B 把 stale 类键迁耐久路径的前提）。

  deadline 类放行谓词统一走 `ApprovalDeadline.not_expired?/2`（nil 永不过期 =
  投递；== now 不放行 = 跳过；与 overdue?/2 不对称对偶，不可代用）；running 类
  status == :running 即投递。非 required_status / 读失败 → stale=true（跳过）；
  未知类型 → false（不重查，现兜底保持）。
  """

  alias Cgc2046.ApprovalDeadline
  alias Cgc2046.Notifications.NotificationWorker

  @doc """
  args 形状与 `NotificationWorker.perform/1` 同款：
  `%{"template_key" => ..., "data" => ...}`。过期 → `true`（跳过发送）；
  无 stale 规格 / id 缺失 / 未知类型 → `false`（照常投递）。
  """
  @spec stale?(map()) :: boolean()
  def stale?(%{"template_key" => template_key, "data" => data}) when is_map(data) do
    case stale_entry(template_key, data) do
      nil ->
        false

      %{id_key: id_key, stale: {resource, required_status, kind}} ->
        case Map.get(data, id_key) do
          id when is_binary(id) -> stale_check(resource, id, required_status, kind)
          # id 缺失/非 binary → false（投递），与收敛前 catch-all 同款
          _ -> false
        end
    end
  end

  def stale?(_args), do: false

  # stale 规格定位：template_key 匹配且带 stale 的条目，按 data 实际携带的
  # id_key 分派；无 stale 条目/未知类型/键缺失 → nil。
  defp stale_entry(template_key, data) do
    NotificationWorker.types()
    |> Enum.filter(&(&1.template_key == template_key and not is_nil(&1.stale)))
    |> Enum.find(&Map.has_key?(data, &1.id_key))
  end

  # 命中 required_status 后的重查判定：deadline 类走放行谓词（未过 → 投递）；
  # running 类 status 命中即投递（无 deadline 概念）。
  defp stale_check(resource, id, required_status, :not_expired) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{status: ^required_status} = record} ->
        not ApprovalDeadline.not_expired?(record, DateTime.utc_now())

      _ ->
        true
    end
  end

  defp stale_check(resource, id, required_status, :running) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{status: ^required_status}} -> false
      _ -> true
    end
  end
end
