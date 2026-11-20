defmodule Cgc2046.LlmGateway.Workers.LlmPaymentSettlementWorker do
  @moduledoc """
  LLM 独立收银台落账 worker（Phase 3B）。

  `PaymentWebhookController` 只按 `LLM_` 前缀分流；现有报名支付
  `PaymentSettlementWorker` 的内部逻辑零改动。

  落账链：
  1. 读 `payments_webhook_events`，取 out_trade_no；从 `llm_payment_orders`
     定位订单（找不到只告警，不误落报名订单）。
  2. `Provider.fetch_transaction` 回查渠道，不信回调金额。
  3. 金额不等 → 不落账，写 `payment_amount_mismatch` Finding（复用既有规则），
     事件标记已消费，等待人工处置。
  4. 金额相等 → 事务内 CAS `pending → paid`，再给个人钱包 / 工作台池入账。
     订单 CAS 与入账同事务；重复回调见已 paid 只标记事件，不二次入账。
  5. 个人订阅 30 天有效；加油包永久；工作台池充值直接增加 `workspace.credit_pool_mc`。
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, states: :incomplete]

  require Logger

  alias Cgc2046.LlmGateway.Ledger
  alias Cgc2046.LlmGateway.PaymentOrders
  alias Cgc2046.Payments.Provider
  alias Cgc2046.Payments.WebhookEvent
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => event_id}}) do
    event = Ash.get!(WebhookEvent, event_id, authorize?: false)

    with {:ok, out_trade_no} <- fetch_out_trade_no(event),
         {:ok, order} <- PaymentOrders.find_by_out_trade_no(out_trade_no) do
      settle(event, order)
    else
      {:error, :out_trade_no_missing} ->
        mark_processed(event)

      {:error, :not_found} ->
        Logger.error("llm settlement: order not found for out_trade_no")
        mark_processed(event)

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  def perform(%Oban.Job{}), do: :ok

  defp settle(event, order) do
    case Provider.for(order.provider).fetch_transaction(order.out_trade_no) do
      {:ok, %{status: :paid, amount_cents: amount, transaction_id: transaction_id}} ->
        if amount == order.amount_cents do
          settle_paid(event, order, transaction_id)
        else
          report_amount_mismatch(event, order, amount)
        end

      {:ok, %{status: _pending_or_closed}} ->
        mark_processed(event)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle_paid(event, order, transaction_id) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        case Repo.query!(
               """
               UPDATE llm_payment_orders
               SET status = 'paid', transaction_id = $2, paid_at = $3, updated_at = $3
               WHERE id = $1 AND status = 'pending'
               RETURNING id
               """,
               [Repo.uuid!(order.id), transaction_id, now]
             ).rows do
          [[_id]] ->
            grant_order(order)
            :settled

          [] ->
            case current_order_status(order.id) do
              "paid" -> :already_processed
              status when status in ["cancelled", "expired"] -> {:closed_order_paid, status}
              other -> {:unexpected_status, other}
            end
        end
      end)

    case result do
      {:ok, :settled} ->
        mark_processed(event)

      {:ok, :already_processed} ->
        mark_processed(event)

      {:ok, {:closed_order_paid, current_status}} ->
        report_closed_order_paid(event, order, current_status, transaction_id)

      {:ok, {:unexpected_status, other}} ->
        Logger.error(
          "llm settlement unexpected order status: out_trade_no=#{order.out_trade_no} " <>
            "status=#{inspect(other)}"
        )

        mark_processed(event)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_order_status(order_id) do
    case Repo.query!(
           "SELECT status FROM llm_payment_orders WHERE id = $1",
           [Repo.uuid!(order_id)]
         ).rows do
      [[status]] -> status
      [] -> nil
    end
  end

  defp report_closed_order_paid(event, order, current_status, transaction_id) do
    Logger.error(
      "llm settlement closed order paid: out_trade_no=#{order.out_trade_no} " <>
        "status=#{current_status} amount_cents=#{order.amount_cents} " <>
        "transaction_id=#{transaction_id}"
    )

    Finding.apply_rule(
      :llm_closed_order_paid,
      [
        %{
          entity_type: :payment_order,
          entity_id: order.id,
          workspace_id: order.workspace_id,
          detail: %{
            "order_source" => "llm_payment_order",
            "out_trade_no" => order.out_trade_no,
            "status" => current_status,
            "amount_cents" => order.amount_cents,
            "transaction_id" => transaction_id
          }
        }
      ],
      sweep: :one_shot,
      log_prefix: "llm_payment"
    )

    mark_processed(event)
  end

  defp grant_order(%{order_kind: :llm_subscription} = order) do
    expires_at = PaymentOrders.grant_expires_at(:llm_subscription)

    case Ledger.grant_personal_credits(order.user_id, %{
           amount_mc: order.credits_mc,
           source_type: :subscription,
           expires_at: expires_at,
           payment_order_id: order.id
         }) do
      {:ok, _wallet} -> :ok
      {:error, reason} -> Repo.rollback({:grant_failed, reason})
    end
  end

  defp grant_order(%{order_kind: :llm_credit_pack} = order) do
    case Ledger.grant_personal_credits(order.user_id, %{
           amount_mc: order.credits_mc,
           source_type: :pack,
           expires_at: nil,
           payment_order_id: order.id
         }) do
      {:ok, _wallet} -> :ok
      {:error, reason} -> Repo.rollback({:grant_failed, reason})
    end
  end

  defp grant_order(%{order_kind: :llm_workspace_pool_topup} = order) do
    case Ledger.topup_workspace_pool(order.workspace_id, order.credits_mc,
           entry_type: :order_topup,
           payment_order_id: order.id,
           actor_user_id: order.user_id
         ) do
      {:ok, _new_pool_mc} -> :ok
      {:error, reason} -> Repo.rollback({:grant_failed, reason})
    end
  end

  defp report_amount_mismatch(event, order, channel_cents) do
    Logger.error(
      "llm settlement amount mismatch: out_trade_no=#{order.out_trade_no} " <>
        "channel=#{channel_cents} local=#{order.amount_cents}"
    )

    Finding.apply_rule(
      :payment_amount_mismatch,
      [
        %{
          entity_type: :payment_order,
          entity_id: order.id,
          workspace_id: order.workspace_id,
          detail: %{
            "order_source" => "llm_payment_order",
            "expected_cents" => order.amount_cents,
            "channel_cents" => channel_cents,
            "local_cents" => order.amount_cents
          }
        }
      ],
      sweep: :one_shot,
      log_prefix: "llm_payment"
    )

    mark_processed(event)
  end

  defp fetch_out_trade_no(%WebhookEvent{payload: %{"out_trade_no" => out_trade_no}})
       when is_binary(out_trade_no) and out_trade_no != "" do
    {:ok, out_trade_no}
  end

  defp fetch_out_trade_no(_event), do: {:error, :out_trade_no_missing}

  defp mark_processed(event) do
    event
    |> Ash.Changeset.for_update(:mark_processed, %{})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
