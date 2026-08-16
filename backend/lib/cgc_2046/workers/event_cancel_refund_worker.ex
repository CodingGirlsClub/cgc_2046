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

  幂等 `:state_based`：全部转换 CAS 守卫（start_refund 只吃 paid、cancel 只吃
  非终态），信号重投/订阅方重启重复执行零多余效果。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended"],
    idempotency: :state_based

  require Ash.Query
  require Logger

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

  defp refund_event_enrollments(event_id, workspace_id) do
    Enrollment
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read!(authorize?: false)
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch -> process_batch(batch, workspace_id) end)

    :ok
  end

  # 逐笔隔离：单笔失败只记 warning，不阻塞其余（部分失败可重投/单笔 retry 收敛）
  defp process_batch(batch, workspace_id) do
    Enum.each(batch, fn enrollment ->
      case enrollment.status do
        :payment_pending -> cancel_enrollment(enrollment, workspace_id)
        :confirmed -> refund_paid_order(enrollment, workspace_id)
        _skipped -> :ok
      end
    end)
  end

  defp cancel_enrollment(enrollment, workspace_id) do
    enrollment
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> log_skip("enrollment", enrollment.id, reason)
    end
  end

  # confirmed 报名的 paid 单逐笔退款；无 paid 单（免缴 confirmed）自然跳过
  defp refund_paid_order(enrollment, workspace_id) do
    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment.id and status == :paid)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn order ->
      order
      |> Ash.Changeset.for_update(:start_refund, %{})
      |> Ash.update(tenant: workspace_id, authorize?: false)
      |> case do
        {:ok, refunding} ->
          %{"order_id" => refunding.id}
          |> PaymentRefundWorker.new()
          |> Oban.insert!()

          :ok

        {:error, reason} ->
          log_skip("order", order.id, reason)
      end
    end)
  end

  defp log_skip(kind, id, reason) do
    Logger.warning("event cancel refund: #{kind} #{id} skipped: #{inspect(reason)}")
  end
end
