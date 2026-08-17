defmodule Cgc2046.Workers.PaymentSettlementWorker do
  @moduledoc """
  支付回调落账 worker（U7，KTD12）——资金落账唯一路径。

  入口（U6，KTD4）：webhook controller 验签后同事务入队，args 只带
  webhook_event_id + provider。

  落账链（R7）：

  1. 读 webhook_event → 解析 out_trade_no → Provider.fetch_transaction 回查渠道
     （不信回调 payload）；
  2. 金额校验（R20）：渠道 total ≠ 订单 amount_cents → 不落账 + Logger +
     telemetry + Finding（规⑦ 前置兜底）；
  3. CAS 订单 pending→paid（transaction_id 回填）→ CAS 报名
     payment_pending→confirmed（settle_paid，补发 completed 信号）；
  4. 报名 CAS 失败分支（KTD12「收款但无对应占位 → 退款」不变量）：
     - 已 confirmed（免缴先落，AE3）或 expired/cancelled（迟到，AE2）→ 订单
       start_refund 迁移 + 入队 PaymentRefundWorker（渠道调用与收尾在 U9）；
  5. 成功：order.paid 信号（mark_paid 挂点）+ 支付成功通知（R22）+ 事件标
     processed。

  幂等（R21）：重复投递由 webhook_events 唯一索引去重；worker 重试重入由双
  CAS 裁决（先落者赢，后到 num_rows=0 走已处理分支）。Oban 重试 max_attempts 5，
  最终 discarded 由对账规⑥/规⑦ 死信可见。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Payments.NotificationTemplates, as: Templates
  alias Cgc2046.Payments.{Order, Provider, WebhookEvent}
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Workers.PaymentRefundWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => event_id}}) do
    event = Ash.get!(WebhookEvent, event_id, authorize?: false)

    with {:ok, out_trade_no} <- fetch_out_trade_no(event),
         {:ok, order} <- fetch_order(out_trade_no) do
      settle(event, order)
    else
      {:skip, :out_trade_no_missing} ->
        # 非支付类回调（退款通知等）：标记消费，退款结果由 U9 worker 处理
        mark_processed(event)

      {:skip, :order_not_found, out_trade_no} ->
        # 渠道有我无：规⑦ 类差异，留给夜间对账（U13）全量核对
        Logger.error("settlement: order not found for out_trade_no=#{out_trade_no}")
        mark_processed(event)
    end
  end

  def perform(%Oban.Job{}), do: :ok

  # ── 落账链 ─────────────────────────────────────────────────────────────────

  defp settle(event, order) do
    case Provider.for(order.provider).fetch_transaction(order.out_trade_no) do
      {:ok, %{status: :paid, amount_cents: amount, transaction_id: transaction_id}} ->
        if amount == order.amount_cents do
          settle_paid(event, order, transaction_id)
        else
          report_amount_mismatch(order, amount)
          mark_processed(event)
        end

      {:ok, %{status: _unpaid_or_terminal}} ->
        # 未支付（等下个回调/对账）或渠道侧已关单——无款可落
        mark_processed(event)

      {:error, reason} ->
        # 渠道查单失败：Oban 重试语义（max_attempts 5）
        {:error, reason}
    end
  end

  defp settle_paid(event, order, transaction_id) do
    case order
         |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: transaction_id})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, paid_order} ->
        confirm_enrollment(event, paid_order)

      {:error, _already_migrated} ->
        handle_late_settlement(event, order)
    end
  end

  # 报名侧 CAS（KTD12）：成功 → 通知收尾；失败不信任错误形状（F-I：CAS
  # num_rows=0 与 DB 瞬断在 Ash error 面不可靠区分），一律 reload 报名真状态
  # 裁决（F-A/F-I 统一入口）。
  defp confirm_enrollment(event, paid_order) do
    enrollment = enrollment_of(paid_order)

    case enrollment
         |> Ash.Changeset.for_update(:settle_paid, %{})
         |> Ash.update(tenant: paid_order.workspace_id, authorize?: false) do
      {:ok, _confirmed} ->
        notify_payment_succeeded(paid_order, enrollment)
        mark_processed(event)

      {:error, _cas_or_db} ->
        reconcile_enrollment(event, paid_order)
    end
  end

  # 订单 CAS 失败分支：expired/cancelled = 迟到扣款命中已作废单（AE2）→
  # 自动退款。cancelled 为过期前被免缴/报名取消/换渠道作废的单——本地作废
  # 不关渠道单，QR 仍可被支付，收款无有效占位必须原路退回（KTD12 不变量）；
  # 其余终态不应发生——记告警由对账兜底。
  defp handle_late_settlement(event, order) do
    case reload_order(order).status do
      :paid ->
        # F-A：订单已 paid 但报名侧可能未推进（两事务间崩溃的半落账）——与
        # confirm_enrollment 失败分支共用报名真状态裁决。
        reconcile_enrollment(event, order)

      status when status in [:expired, :cancelled] ->
        enqueue_auto_refund(order)
        mark_processed(event)

      # F-C:重复投递到已进退款链的订单是预期路径(迟到回调撞上已发起的退款/
      # 已完成退款),降 info;真 unexpected(如 refund_failed 单又有款)保持 error。
      status when status in [:refunding, :refunded] ->
        Logger.info(
          "settlement: order #{order.id} already in refund flow (#{status}), delivery skipped"
        )

        mark_processed(event)

      other ->
        Logger.error("settlement: unexpected order status #{other} for #{order.id}")
        mark_processed(event)
    end
  end

  # F-A/F-I 报名真状态裁决（唯一真理 = reload 后的 enrollments 行）：
  # - payment_pending：settle_paid 未执行（半落账/DB 回包丢失）→ 补落账收敛；
  #   补执行再失败（DB 仍故障）→ {:error, reason} 上抛走 Oban 重试，
  #   绝不误触自动退款（F-I）；
  # - confirmed + 免缴留痕（AdminActionLog waive_payment）：免缴竞态（AE3）→
  #   收款无对应有效占位 → 自动退款；
  # - confirmed 无留痕：settle_paid 自己写的（完整重放/UPDATE 已提交回包丢失）
  #   → 幂等无操作，通知 unique 幂等补发（防 notify 前崩溃丢通知）；
  # - expired/cancelled/rejected：迟到/取消 → 自动退款（KTD12 不变量）；
  # - reload 失败（DB）→ {:error, reason} 上抛重试。
  defp reconcile_enrollment(event, order) do
    case Ash.get(Enrollment, order.enrollment_id, authorize?: false) do
      {:ok, %{status: :payment_pending} = enrollment} ->
        enrollment
        |> Ash.Changeset.for_update(:settle_paid, %{})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)
        |> case do
          {:ok, confirmed} ->
            notify_payment_succeeded(order, confirmed)
            mark_processed(event)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: :confirmed} = enrollment} ->
        case waived?(enrollment) do
          {:ok, true} ->
            enqueue_auto_refund(order)
            mark_processed(event)

          {:ok, false} ->
            notify_payment_succeeded(order, enrollment)
            mark_processed(event)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: status}} when status in [:expired, :cancelled, :rejected] ->
        enqueue_auto_refund(order)
        mark_processed(event)

      {:ok, %{status: other}} ->
        Logger.error("settlement: unexpected enrollment status #{other} for order #{order.id}")

        {:error, {:unexpected_enrollment_status, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 免缴判定（F-A 区分线索）：waive_payment action 的 LogAdminAction 与状态
  # confirmed 同事务留痕（fail-closed，log 失败整个免缴回滚），存在性精确 ⇔
  # 免缴先落。approved_by 不可用作线索——审批制收费的 prepare_confirm 在
  # pending→payment_pending 时也写 approved_by（enrollment.ex:498）。
  defp waived?(enrollment) do
    AdminActionLog
    |> Ash.Query.filter(action == :waive_payment and target_id == ^enrollment.id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_ | _]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  # 自动退款（KTD12 共用不变量）：start_refund（paid|expired → refunding）+ 入队
  # 退款 job；渠道调用与收尾（refunded/报名/通知）由 U9 worker 消费。
  defp enqueue_auto_refund(order) do
    case order
         |> Ash.Changeset.for_update(:start_refund, %{})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, refunding} ->
        %{"order_id" => refunding.id}
        |> PaymentRefundWorker.new()
        |> Oban.insert!()

        :ok

      {:error, _already_refunding} ->
        # 并发重试已推进（重入幂等）
        :ok
    end
  end

  # ── 通知（R22：支付成功 → 报名人；契约 = Payments.NotificationTemplates）──

  defp notify_payment_succeeded(order, enrollment) do
    recipients = {enrollment.user_id, Cgc2046.NotificationFanout.identities(enrollment.user_id)}

    Cgc2046.NotificationFanout.deliver(
      recipients,
      Templates.payment_succeeded(),
      Templates.payment_data(order),
      %{"idempotency_key" => Templates.payment_succeeded() <> ":" <> order.id}
    )
  end

  # ── 金额不符（R20）──────────────────────────────────────────────────────

  defp report_amount_mismatch(order, channel_amount) do
    Logger.error(
      "settlement: amount mismatch order=#{order.id} expected=#{order.amount_cents} channel=#{channel_amount}"
    )

    :telemetry.execute(
      [:cgc2046, :payment_settlement, :amount_mismatch],
      %{count: 1},
      %{order_id: order.id, expected: order.amount_cents, channel: channel_amount}
    )

    Finding
    |> Ash.Changeset.for_create(:create, %{
      rule: :payment_amount_mismatch,
      entity_type: :payment_order,
      entity_id: order.id,
      workspace_id: order.workspace_id,
      detail: %{"expected_cents" => order.amount_cents, "channel_cents" => channel_amount}
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, _duplicate} -> :ok
    end
  end

  # ── 工具 ───────────────────────────────────────────────────────────────────

  defp fetch_out_trade_no(%{payload: payload}) do
    case payload["out_trade_no"] do
      out_trade_no when is_binary(out_trade_no) and out_trade_no != "" ->
        {:ok, out_trade_no}

      _ ->
        {:skip, :out_trade_no_missing}
    end
  end

  defp fetch_order(out_trade_no) do
    case Order
         |> Ash.Query.filter(out_trade_no == ^out_trade_no)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:skip, :order_not_found, out_trade_no}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrollment_of(order) do
    Cgc2046.Events.Enrollment
    |> Ash.get!(order.enrollment_id, authorize?: false)
  end

  defp reload_order(order) do
    Ash.get!(Order, order.id, tenant: order.workspace_id, authorize?: false)
  end

  defp mark_processed(event) do
    event
    |> Ash.Changeset.for_update(:mark_processed, %{})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
