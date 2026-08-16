defmodule Cgc2046.Workers.PaymentRefundWorker do
  @moduledoc """
  退款渠道调用 worker（U9/F3，R15-R17——退款即取消，ADR-0007）。

  消费两类入队源：
  - U7 落账 worker 的自动退款（迟到扣款 AE2 / 免缴竞态 AE3——收款但无对应占位）；
  - U9 退款 action（管理员单笔 refund / retry_refund / Event cancelled 批量）。

  单笔链路（查单优先，回调丢失兜底内建）：

  1. 订单非 refunding → 幂等 :ok（重放/竞态/已终态）；
  2. `Provider.fetch_transaction` 查单：渠道侧已 :refunded（退款回调先落或
     上一轮受理已成功）→ 直接收尾，不重复调渠道退款；
  3. 调 `Provider.refund`：支付宝同步结果立即再查单收敛；微信异步受理
     (:ok 但未终态) → 返回 `{:error, :refund_pending}` 走 Oban 重试——每次
     重入都从步骤 2 查单开始，即「回调丢失时重试路径主动查单」的兜底语义；
     重试耗尽 discarded 由 U13 规⑦「refunding 卡死」死信可见 + 管理员
     retry_refund 重入；
  4. 渠道拒绝 → mark_refund_failed + 双方通知（R22），可经 retry_refund 重试；
  5. refunded 收尾：CAS refunding→refunded（refunded_at）→ 报名 :cancel
     （cancelled + 名额释放 + 作废残留 pending 订单，内置 CAS）→ 通知双方。

  通知（R22）：退款成功/失败 → 报名人 + workspace 管理者（自动退款无发起
  人，管理者面即「发起管理员」超集；best-effort，不影响资金状态）。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Logger

  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Payments.{Order, Provider}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) do
    order = Ash.get!(Order, order_id, authorize?: false)

    case order.status do
      :refunding -> drive_refund(order)
      _other -> :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  # ── 退款主链 ─────────────────────────────────────────────────────────────

  defp drive_refund(order) do
    provider = Provider.for(order.provider)

    case provider.fetch_transaction(order.out_trade_no) do
      {:ok, %{status: :refunded}} ->
        finalize(order)

      {:ok, _not_final} ->
        request_channel_refund(order, provider)

      {:error, reason} ->
        # 查单失败：Oban 重试语义（max_attempts 5）
        {:error, reason}
    end
  end

  defp request_channel_refund(order, provider) do
    case provider.refund(order) do
      :ok ->
        # 受理成功：支付宝同步结果立即收敛；微信异步等回调（重试查单兜底）。
        case provider.fetch_transaction(order.out_trade_no) do
          {:ok, %{status: :refunded}} -> finalize(order)
          {:ok, _pending_channel} -> {:error, :refund_pending}
          {:error, reason} -> {:error, reason}
        end

      {:error, :channel_refund_failed} ->
        # 渠道明确拒绝（adapter 归一）：终态 refund_failed，可 retry_refund 重入
        fail_refund(order, :channel_refund_failed)

      {:error, reason} ->
        # 传输/配置类瞬时错误：不落终态，Oban 重试（max_attempts 5）
        {:error, reason}
    end
  end

  # ── 终态收尾 ─────────────────────────────────────────────────────────────

  defp finalize(order) do
    case order
         |> Ash.Changeset.for_update(:refund_succeeded, %{})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, refunded} ->
        cancel_enrollment(refunded)
        notify_refund(refunded, "refund_succeeded")
        :ok

      {:error, _already_refunded} ->
        # 重放幂等（回调先落 + worker 重入并发，CAS 裁决）
        :ok
    end
  end

  defp fail_refund(order, reason) do
    Logger.error("refund: order #{order.id} channel rejected: #{inspect(reason)}")

    case order
         |> Ash.Changeset.for_update(:mark_refund_failed, %{})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, failed} ->
        notify_refund(failed, "refund_failed")
        :ok

      {:error, _already_migrated} ->
        :ok
    end
  end

  # 退款即取消（R16）：confirmed 报名 → cancelled + 名额释放（enrollment.cancel
  # 内置 CAS + confirmed_count 回落 + 作废残留 pending 订单）。迟到退款路径
  # 报名已 expired/cancelled → CAS num_rows=0 跳过（名额已释）。
  defp cancel_enrollment(order) do
    Ash.get!(Enrollment, order.enrollment_id, authorize?: false)
    |> Ash.Changeset.for_update(:cancel, %{})
    |> Ash.update(tenant: order.workspace_id, authorize?: false)
    |> case do
      {:ok, _cancelled} -> :ok
      {:error, _already_terminal} -> :ok
    end
  end

  # ── 通知（R22：退款结果 → 报名人 + 管理者；模板渲染 U10 定稿）──────────

  defp notify_refund(order, template_key) do
    enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

    recipients =
      %{enrollment.user_id => Cgc2046.NotificationFanout.identities(enrollment.user_id)}
      |> Map.merge(Cgc2046.NotificationFanout.managers(order.workspace_id))

    Cgc2046.NotificationFanout.deliver(
      recipients,
      template_key,
      %{
        "order_id" => order.id,
        "enrollment_id" => order.enrollment_id,
        "amount_cents" => order.amount_cents,
        "provider" => to_string(order.provider)
      },
      %{"idempotency_key" => template_key <> ":" <> order.id}
    )
  end
end
