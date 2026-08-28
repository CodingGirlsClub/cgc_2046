defmodule Cgc2046.Workers.OfferingCancelRefundWorker do
  @moduledoc """
  Event/Course cancelled 批量退款（payment-loop U9/F3 + organizer-payment U2，
  R15——退款即取消，ADR-0007）。

  订阅 `event.ended` / `course.ended`（D4：closed 与 cancelled 共用信号；双信号
  按 payload 键分派，先例 Curriculum.Reaper）→ **回查实体 status** 仅 `cancelled`
  触发退款批量（closed = 正常结束，不退）；逐笔隔离，部分失败只记 warning 不
  阻塞其余（下一波信号重投/管理员单笔 retry 兜底）：

  - paid 订单 → 内部 `:start_refund` CAS + 入队 `PaymentRefundWorker`
    （渠道调用与收尾同单笔链；系统驱动无 actor，不走管理员 :refund action）；
  - payment_pending 报名 → `Enrollment :cancel`（cancelled + 名额释放 +
    作废 pending 订单，内置 CAS）；
  - expired / cancelled / refunding / refund_failed / refunded / confirmed 无
    paid 单（免缴）→ 跳过（Assumptions 批量矩阵）。

  治理（advisory 清偿）：

  - **F-D 分页**：报名按 keyset 游标分批拉取（`id > cursor` + limit @batch_size），
    不再全量 load——大活动内存峰值与首响延迟受控；
  - **F-J 审计**：批量动作落 `AdminActionLog`（action = :event_cancel_batch_refund
    / :course_cancel_batch_refund，actor_id = nil 系统语义同 CLI 先例；每实体
    一行，metadata 带取消/退款计数与 order id 列表）。

  幂等 `:state_based`：全部转换 CAS 守卫（start_refund 只吃 paid、cancel 只吃
  非终态），信号重投/订阅方重启重复执行零多余效果。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.ended", "course.ended"],
    idempotency: :state_based

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event
  alias Cgc2046.Payments.Order
  alias Cgc2046.Workers.PaymentRefundWorker

  # 分批步长（plan U9-3 批大小常量）：控制单波对 payments 队列的瞬时入队量
  @batch_size 50

  # 审计 action 按 offering kind 分派（Event/Course 各自的批量退款值）
  @batch_actions %{event: :event_cancel_batch_refund, course: :course_cancel_batch_refund}

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id),
    do: resolve_and_refund(Event, :event, event_id)

  def handle(_type, %{"course_id" => course_id}) when is_binary(course_id),
    do: resolve_and_refund(Course, :course, course_id)

  def handle(_type, _data), do: :ok

  # 回查实体状态后分派：cancelled → 批量退款；closed → 明确不退；未定态 →
  # 不认领等信号重投（ended 信号先于终态可见的竞态窗口）。
  defp resolve_and_refund(module, kind, id) do
    case Ash.get(module, id, authorize?: false) do
      {:ok, %{status: :cancelled, workspace_id: workspace_id}} ->
        refund_offering_enrollments(kind, id, workspace_id)

      {:ok, %{status: :closed}} ->
        # closed = 正常结束（D4），不属于取消退款面
        :ok

      {:ok, _other_status} ->
        {:error, {:offering_status_not_settled, kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A2：ended 信号重投（订阅方重启/Oban 重试）对已处理完的 offering 是预期
  # 路径——零效果不落新审计行（首行已记录批量结果，重投行只有 0/0/0 噪音）。
  defp refund_offering_enrollments(kind, id, workspace_id) do
    counts =
      stream_offering_enrollments(kind, id)
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(fn batch -> process_batch(batch, workspace_id) end)
      |> Enum.reduce(%{cancelled: 0, refunded: 0, skipped: 0}, &merge_counts/2)

    unless counts == %{cancelled: 0, refunded: 0, skipped: 0} do
      log_batch_audit(kind, id, counts)
    end

    :ok
  end

  defp enrollment_scope(:event, id), do: Ash.Query.filter(Enrollment, event_id == ^id)
  defp enrollment_scope(:course, id), do: Ash.Query.filter(Enrollment, course_id == ^id)

  defp stream_offering_enrollments(kind, id) do
    Stream.unfold("", fn cursor ->
      batch =
        enrollment_scope(kind, id)
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

  # 逐笔隔离：单笔失败只记 warning，不阻塞其余（部分失败可重投/单笔 retry 收敛）。
  # review F4：paid 订单是退款真源——报名在异步窗口内可能已被学员取消
  # （cancelled），其 paid 单仍必须退；支付态报名才走取消释放面。
  defp process_batch(batch, workspace_id) do
    Enum.reduce(batch, %{cancelled: 0, refunded: 0, skipped: 0}, fn enrollment, acc ->
      # paid 单不问报名状态（已付必退，ADR-0007 取消即批量退）
      n = refund_paid_order(enrollment, workspace_id)
      acc = Map.update!(acc, :refunded, &(&1 + n))

      case enrollment.status do
        :payment_pending ->
          case cancel_enrollment(enrollment, workspace_id) do
            :ok -> Map.update!(acc, :cancelled, &(&1 + 1))
            :skip -> Map.update!(acc, :skipped, &(&1 + 1))
          end

        :confirmed ->
          # paid 单已在上面处理；免缴 confirmed（无 paid 单）自然零增量
          acc

        _skipped ->
          Map.update!(acc, :skipped, &(&1 + 1))
      end
    end)
  end

  # F-J：批量退款审计留痕（系统动作，actor_id = nil 同 CLI 语义；每 event 一行）
  defp log_batch_audit(kind, id, counts) do
    case AdminActionLog.log(%{
           actor_id: nil,
           action: @batch_actions[kind],
           target_type: kind,
           target_id: id,
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
          "offering cancel refund: audit log failed for #{kind} #{id}: #{inspect(reason)}"
        )
    end
  end

  defp cancel_enrollment(enrollment, workspace_id) do
    enrollment
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update(tenant: workspace_id, authorize?: false)
    |> case do
      {:ok, _} -> :ok
      # log_skip 返回 :skip（计数口径：cancelled 只计成功行）
      {:error, reason} -> log_skip("enrollment", enrollment.id, reason)
    end
  end

  # confirmed 报名的 paid 单逐笔退款；无 paid 单（免缴 confirmed）自然跳过。
  # 返回成功入队数（F-J 审计计数）。review F3：transition + 入队同事务——
  # 崩溃窗口不留「refunding 无 job」悬挂态；事务回滚后重投信号从 paid 重扫。
  defp refund_paid_order(enrollment, workspace_id) do
    Order
    |> Ash.Query.filter(enrollment_id == ^enrollment.id and status == :paid)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn order, acc ->
      case Cgc2046.Repo.transaction(fn ->
             with {:ok, refunding} <-
                    order
                    |> Ash.Changeset.for_update(:start_refund, %{})
                    |> Ash.update(tenant: workspace_id, authorize?: false),
                  {:ok, _job} <- enqueue_refund_job(refunding) do
               {:ok, refunding.id}
             end
           end) do
        {:ok, {:ok, _order_id}} ->
          acc + 1

        {:ok, {:error, reason}} ->
          log_skip("order", order.id, reason)
          acc

        {:error, reason} ->
          log_skip("order", order.id, reason)
          acc
      end
    end)
  end

  # Oban.insert! 直入 oban_jobs 表（同连接同事务）——与 start_refund CAS 原子提交
  defp enqueue_refund_job(refunding) do
    {:ok, Oban.insert!(PaymentRefundWorker.new(%{"order_id" => refunding.id}))}
  end

  defp log_skip(kind, id, reason) do
    Logger.warning("offering cancel refund: #{kind} #{id} skipped: #{inspect(reason)}")
    # 计数口径：跳过（cancelled/refunded 只计成功行，审计 metadata 不虚高）
    :skip
  end
end
