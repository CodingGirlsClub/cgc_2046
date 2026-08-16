defmodule Cgc2046.Workers.EventCancelRefundWorker do
  @moduledoc """
  Event cancelled 批量退款（U9/F3，R15——退款即取消，ADR-0007）。

  订阅 `event.ended`（D4：closed 与 cancelled 共用信号）→ **回查 Event.status**
  仅 `cancelled` 触发退款批量（closed = 正常结束，不退）；逐笔隔离，部分失败
  只记 warning 不阻塞其余（下一波信号重投/管理员单笔 retry 兜底）：

  - paid 订单 → 内部 `:start_refund` CAS + 入队 `PaymentRefundWorker`
    （渠道调用与收尾同单笔链；系统驱动无 actor，不走管理员 :refund action）；
  - payment_pending 报名 → `Enrollment :cancel`（cancelled + 名额释放 +
    作废 pending 订单，内置 CAS）；
  - expired / cancelled / refunding / refund_failed / refunded / confirmed 无
    paid 单（免缴）→ 跳过（Assumptions 批量矩阵）。

  治理（advisory 清偿）：

  - **F-D 分页**：报名按 keyset 游标分批拉取（`id > cursor` + limit @batch_size），
    不再全量 load——大活动内存峰值与首响延迟受控；
  - **F-J 审计**：批量动作落 `AdminActionLog`（action = :event_cancel_batch_refund，
    actor_id = nil 系统语义同 CLI 先例；每 event 一行，metadata 带取消/退款计数
    与 order id 列表）。

  幂等 `:state_based`：全部转换 CAS 守卫（start_refund 只吃 paid、cancel 只吃
  非终态），信号重投/订阅方重启重复执行零多余效果。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended"],
    idempotency: :state_based

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Events.{Enrollment, Event}
  alias Cgc2046.Payments.Order
  alias Cgc2046.Workers.PaymentRefundWorker

  # 分批步长（plan U9-3 批大小常量）：控制单波对 payments 队列的瞬时入队量
  @batch_size 50

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, %Event{status: :cancelled, workspace_id: workspace_id}} ->
        refund_event_enrollments(event_id, workspace_id)

      {:ok, %Event{status: :closed}} ->
        # closed = 正常结束（D4），不属于取消退款面
        :ok

      {:ok, _other_status} ->
        # ended 信号先于终态可见的竞态或非预期状态：不 claim，重投再试
        {:error, :event_status_not_settled}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(_type, _data), do: :ok

  # F-D：keyset 游标分页拉取（不全量 load）。排序键 = id（uuid 稳定全序）。
  defp refund_event_enrollments(event_id, workspace_id) do
    counts =
      stream_event_enrollments(event_id)
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(fn batch -> process_batch(batch, workspace_id) end)
      |> Enum.reduce(%{cancelled: 0, refunded: 0, skipped: 0}, &merge_counts/2)

    log_batch_audit(event_id, counts)

    :ok
  end

  defp stream_event_enrollments(event_id) do
    Stream.unfold("", fn cursor ->
      batch =
        Enrollment
        |> Ash.Query.filter(event_id == ^event_id)
        |> Ash.Query.sort(id: :asc)
        |> then(fn q ->
          if cursor == "" do
            q
          else
            Ash.Query.filter(q, id > ^cursor)
          end
        end)
        |> Ash.Query.limit(@batch_size)
        |> Ash.read!(authorize?: false)

      case batch do
        [] -> nil
        rows -> {rows, List.last(rows).id}
      end
    end)
    |> Stream.flat_map(& &1)
  end

  defp merge_counts(a, b) do
    Map.merge(a, b, fn _k, x, y -> x + y end)
  end

  # 逐笔隔离：单笔失败只记 warning，不阻塞其余（部分失败可重投/单笔 retry 收敛）
  defp process_batch(batch, workspace_id) do
    Enum.reduce(batch, %{cancelled: 0, refunded: 0, skipped: 0}, fn enrollment, acc ->
      case enrollment.status do
        :payment_pending ->
          case cancel_enrollment(enrollment, workspace_id) do
            :ok -> Map.update!(acc, :cancelled, &(&1 + 1))
            :skip -> Map.update!(acc, :skipped, &(&1 + 1))
          end

        :confirmed ->
          n = refund_paid_order(enrollment, workspace_id)
          Map.update!(acc, :refunded, &(&1 + n))

        _skipped ->
          Map.update!(acc, :skipped, &(&1 + 1))
      end
    end)
  end

  # F-J：批量退款审计留痕（系统动作，actor_id = nil 同 CLI 语义；每 event 一行）
  defp log_batch_audit(event_id, counts) do
    case AdminActionLog.log(%{
           actor_id: nil,
           action: :event_cancel_batch_refund,
           target_type: :event,
           target_id: event_id,
           metadata: %{
             "cancelled_enrollments" => counts.cancelled,
             "refunded_orders" => counts.refunded,
             "skipped" => counts.skipped
           }
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "event cancel refund: audit log failed for event #{event_id}: #{inspect(reason)}"
        )
    end
  end

  defp cancel_enrollment(enrollment, workspace_id) do
    enrollment
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> log_skip("enrollment", enrollment.id, reason)
    end
    # log_skip 返回 :skip(计数口径)
    |> then(fn
      :ok -> :ok
      _ -> :skip
    end)
  end

  # confirmed 报名的 paid 单逐笔退款；无 paid 单（免缴 confirmed）自然跳过。
  # 返回成功入队数（F-J 审计计数）。
  defp refund_paid_order(enrollment, workspace_id) do
    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment.id and status == :paid)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn order, acc ->
      order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace_id, authorize?: false)
      |> case do
        {:ok, refunding} ->
          %{"order_id" => refunding.id}
          |> PaymentRefundWorker.new()
          |> Oban.insert!()

          acc + 1

        {:error, reason} ->
          log_skip("order", order.id, reason)
          acc
      end
    end)
  end

  defp log_skip(kind, id, reason) do
    Logger.warning("event cancel refund: #{kind} #{id} skipped: #{inspect(reason)}")
  end
end
