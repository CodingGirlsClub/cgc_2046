defmodule Cgc2046.Workers.PaymentRefundWorker do
  @moduledoc """
  退款渠道调用 worker（U9/F3，R15-R17——退款即取消，ADR-0007）。

  消费两类入队源：
  - U7 落账 worker 的自动退款（迟到扣款 AE2 / 免缴竞态 AE3——收款但无对应占位）；
  - U9 退款 action（管理员单笔 refund / retry_refund / Event cancelled 批量）。

  单笔链路（查单优先，回调丢失兜底内建）：

  1. 状态门：`:refunding` → 驱动退款；`:refunded` → 收尾自愈（F-B，见下）；
     其余终态幂等 `:ok`；
  2. `Provider.fetch_transaction` 查单：渠道侧已 :refunded（退款回调先落或
     上一轮受理已成功）→ 直接收尾，不重复调渠道退款；
  3. 调 `Provider.refund`（KTD17 渠道差异在 adapter 内吸收）：
     - `{:ok, :completed}`（支付宝同步语义）→ 直接收尾，免查单免重试；
     - `:ok`（微信异步受理）→ 再查一次单（覆盖受理即完成的快路径）；未终态
       → `{:error, :refund_pending}` 走 Oban 重试——每次重入都从步骤 2 查单
       开始，即「退款回调丢失时重试路径主动查单」的兜底语义；重试耗尽
       discarded 由 U13 规⑦「refunding 卡死」死信可见 + 管理员 retry_refund 重入；
     - `{:error, :channel_refund_failed}`（渠道明确拒绝，adapter 归一）→
       mark_refund_failed + 双方通知，可经 retry_refund 重试；
     - 其余 `{:error, reason}`（传输/配置类瞬时错误）→ 上抛走 Oban 重试，
       不落终态；
  4. refunded 收尾（三步，非原子——F-B 靠重入自愈闭环）：CAS refunding→refunded
     （refunded_at）→ 报名 :cancel（cancelled + 名额释放 + 作废残留 pending 订单）
     → 通知双方。任一步后崩溃，Oban 重入经 `:refunded` 状态门补齐剩余步骤；
     报名取消失败（非合法竞态）返回 `{:error, reason}` 让重试收敛，不吞错。

  通知（R22）：退款成功/失败 → 报名人 + workspace 管理者（自动退款无发起
  人，管理者面即「发起管理员」超集；best-effort，不影响资金状态；args 幂等
  键 + NotificationWorker unique 使重入补发天然去重）。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Logger

  alias Cgc2046.Events.Enrollment
  alias Cgc2046.Payments.{Order, Provider}
  alias Cgc2046.Payments.NotificationTemplates, as: Templates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id} = args}) do
    order = Ash.get!(Order, order_id, authorize?: false)
    initiator = Map.get(args, "initiator_user_id")

    case order.status do
      :refunding ->
        drive_refund(order, initiator)

      :refunded ->
        # F-B：退款终态已落但收尾（报名取消/通知）可能因两事务间崩溃而未完成
        # ——幂等补齐，直至报名离开占位态。
        ensure_refund_completed(order, initiator)

      _terminal ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  # ── 退款主链 ─────────────────────────────────────────────────────────────

  defp drive_refund(order, initiator) do
    provider = Provider.for(order.provider)

    case provider.fetch_transaction(order.out_trade_no) do
      {:ok, %{status: :refunded}} ->
        finalize(order, initiator)

      {:ok, _not_final} ->
        request_channel_refund(order, provider, initiator)

      {:error, reason} ->
        # 查单失败：Oban 重试语义（max_attempts 5）
        {:error, reason}
    end
  end

  defp request_channel_refund(order, provider, initiator) do
    case provider.refund(order) do
      {:ok, :completed} ->
        # 支付宝同步完成（KTD17 adapter 吸收）：直接收尾，免查单免重试。
        finalize(order, initiator)

      :ok ->
        # 微信异步受理：受理即查一次（覆盖受理即完成的快路径）；未终态交
        # 重试窗查单兜底（重入从 drive_refund 顶部查单开始）。
        case provider.fetch_transaction(order.out_trade_no) do
          {:ok, %{status: :refunded}} -> finalize(order, initiator)
          {:ok, _pending_channel} -> {:error, :refund_pending}
          {:error, reason} -> {:error, reason}
        end

      {:error, :channel_refund_failed} ->
        # 渠道明确拒绝（adapter 归一）：终态 refund_failed，可 retry_refund 重入
        fail_refund(order, :channel_refund_failed, initiator)

      {:error, reason} ->
        # 传输/配置类瞬时错误：不落终态，Oban 重试（max_attempts 5）
        {:error, reason}
    end
  end

  # ── 终态收尾 ─────────────────────────────────────────────────────────────

  defp finalize(order, initiator) do
    case order
         |> Ash.Changeset.for_update(:refund_succeeded, %{})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, refunded} ->
        ensure_refund_completed(refunded, initiator)

      {:error, _already_refunded} ->
        # CAS 失败 = 已 refunded（重放/上轮完成/DB 回包丢失但已提交）——统一走
        # 收尾自愈（报名真状态裁决），与 :refunded 状态门同一条路径。
        ensure_refund_completed(order, initiator)
    end
  end

  # F-B 收尾保障：退款终态（本回合落定或上轮已落）后确保报名取消 + 通知完成；
  # 取消失败上抛走 Oban 重试，经 :refunded 状态门重入本路径收敛。
  defp ensure_refund_completed(order, initiator) do
    case cancel_enrollment(order) do
      :ok ->
        notify_refund(order, Templates.refund_succeeded(), initiator)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail_refund(order, reason, initiator) do
    Logger.error("refund: order #{order.id} channel rejected: #{inspect(reason)}")

    case order
         |> Ash.Changeset.for_update(:mark_refund_failed, %{})
         |> Ash.update(tenant: order.workspace_id, authorize?: false) do
      {:ok, failed} ->
        notify_refund(failed, Templates.refund_failed(), initiator)
        :ok

      {:error, _already_migrated} ->
        :ok
    end
  end

  # 退款即取消（R16）：confirmed 报名 → cancelled + 名额释放（enrollment.cancel
  # 内置 CAS + confirmed_count 回落 + 作废残留 pending 订单）。
  # F-B：失败不吞错——reload 真状态裁决：已终态（cancelled/expired/rejected）=
  # 合法竞态/迟到路径已处理；仍占位 = 真失败（capacity_counter_invalid / DB
  # 瞬断）→ {:error, reason} 让 Oban 重试收敛，拒绝「钱已退、坑还占」。
  defp cancel_enrollment(order) do
    case Ash.get(Enrollment, order.enrollment_id, authorize?: false) do
      {:ok, %{status: status}} when status in [:cancelled, :expired, :rejected] ->
        :ok

      {:ok, enrollment} ->
        enrollment
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(tenant: order.workspace_id, authorize?: false)
        |> case do
          {:ok, _cancelled} ->
            :ok

          {:error, reason} ->
            settle_cancel_failure(order, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_cancel_failure(order, reason) do
    case Ash.get(Enrollment, order.enrollment_id, authorize?: false) do
      {:ok, %{status: status}} when status in [:cancelled, :expired, :rejected] ->
        # cancel 失败但报名已终态 = 并发取消/过期先落（合法竞态）
        :ok

      {:ok, %{status: still_holding}} ->
        Logger.error(
          "refund: enrollment #{order.enrollment_id} cancel failed after refund " <>
            "#{order.id} (still #{still_holding}): #{inspect(reason)}"
        )

        {:error, {:cancel_failed, reason}}

      {:error, reload_reason} ->
        {:error, reload_reason}
    end
  end

  # ── 通知（R22：退款结果 → 报名人 + 发起人/管理者；契约 = NotificationTemplates）──

  # R22 发起人精确归属（U10 定稿）：单笔管理员退款/重试经 job args 携带
  # initiator_user_id（mutation actor）——收件人精确到「报名人 + 发起管理员」；
  # 自动退款/批量（U7/E-C 入队）无 actor → 报名人 + workspace 管理者超集。
  defp notify_refund(order, template_key, initiator_user_id)
       when is_binary(initiator_user_id) do
    enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

    recipients =
      %{enrollment.user_id => Cgc2046.NotificationFanout.identities(enrollment.user_id)}
      |> Map.merge(%{
        initiator_user_id => Cgc2046.NotificationFanout.identities(initiator_user_id)
      })

    deliver_refund(recipients, order, template_key)
  end

  defp notify_refund(order, template_key, _no_initiator) do
    enrollment = Ash.get!(Enrollment, order.enrollment_id, authorize?: false)

    recipients =
      %{enrollment.user_id => Cgc2046.NotificationFanout.identities(enrollment.user_id)}
      |> Map.merge(Cgc2046.NotificationFanout.managers(order.workspace_id))

    deliver_refund(recipients, order, template_key)
  end

  defp deliver_refund(recipients, order, template_key) do
    Cgc2046.NotificationFanout.deliver(
      recipients,
      template_key,
      Templates.payment_data(order),
      %{"idempotency_key" => template_key <> ":" <> order.id}
    )
  end
end
