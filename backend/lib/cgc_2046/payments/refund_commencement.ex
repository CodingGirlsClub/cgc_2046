defmodule Cgc2046.Payments.RefundCommencement do
  @moduledoc """
  退款发起单一入口（#845；ADR-0007 §3 六类发起方的唯一 seam）。

  按订单状态分派 `start_refund` / `retry_refund`，CAS 竞态只用一种办法收敛：
  重读一次，重新分类。入队由 Order action 的 `after_action` 承担（#845 D1，
  恰好一次），本模块不插手 job。

  本模块只做分类与推进，不替调用方决定结果处理：哪些订单合格（`eligible`）、
  拿到结果后抛错、跳过还是回滚，都留在调用方。`refunding` / `refunded` 恒为
  `{:ok, :already_in_progress}`（race 契约在 seam 上定义一次，与 eligible 正交）；
  其余不可发起的状态返回 `{:error, {:ineligible, status}}`，由调用方按自身
  语义分派（如核销面把 `:forfeited` 转业务错误、把 `:pending` 当良性）。

  返回封闭结果集：

    {:ok, :started}                 paid → refunding
    {:ok, :retried}                 refund_failed → refunding
    {:ok, :already_in_progress}     refunding / refunded（含竞态重读后收敛）
    {:error, {:ineligible, status}} 不可发起且非在途 / 已退
    {:error, reason}                Ash 错误原样（DB 故障、竞态重读未收敛等）
  """

  alias Cgc2046.Payments.Order

  @refund_in_flight [:refunding, :refunded]

  @spec commence(Order.t(), keyword()) ::
          {:ok, :started | :retried | :already_in_progress}
          | {:error, {:ineligible, atom()} | term()}

  def commence(order, opts) do
    eligible = Keyword.fetch!(opts, :eligible)

    classify(order.status, eligible) |> settle(order, eligible, true)
  end

  defp classify(status, eligible) do
    cond do
      status == :paid and :paid in eligible -> {:run, :start_refund, :started}
      status == :refund_failed and :refund_failed in eligible -> {:run, :retry_refund, :retried}
      status in @refund_in_flight -> {:in_flight}
      true -> {:ineligible, status}
    end
  end

  defp settle({:in_flight}, _order, _eligible, _retriable?), do: {:ok, :already_in_progress}

  defp settle({:ineligible, status}, _order, _eligible, _retriable?),
    do: {:error, {:ineligible, status}}

  # retriable?: false = 竞态重读后的第二次推进，再失败即真故障，透传原始错误
  defp settle({:run, action, ok_tag}, order, eligible, retriable?) do
    case order
         |> Ash.Changeset.for_update(action, %{})
         |> Ash.update(authorize?: false, tenant: order.workspace_id) do
      {:ok, _refunding} ->
        {:ok, ok_tag}

      {:error, reason} ->
        if retriable? do
          reread_and_reclassify(order, eligible, reason)
        else
          {:error, reason}
        end
    end
  end

  # CAS 输了只用一种办法：重读一次，重新分类。状态未变（他路回滚 / 纯故障）
  # 不重复尝试，透传原始 reason——与 attendance 侧 reevaluate_transition 同语义。
  defp reread_and_reclassify(order, eligible, reason) do
    case Ash.get(Order, order.id, tenant: order.workspace_id, authorize?: false) do
      {:ok, %{status: fresh_status} = fresh} when fresh_status != order.status ->
        classify(fresh_status, eligible) |> settle(fresh, eligible, false)

      {:ok, _unchanged} ->
        {:error, reason}

      {:error, reread_error} ->
        {:error, reread_error}
    end
  end
end
