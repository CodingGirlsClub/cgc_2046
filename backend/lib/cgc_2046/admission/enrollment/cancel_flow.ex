defmodule Cgc2046.Admission.Enrollment.CancelFlow do
  @moduledoc """
  cancel 流（#851 架构深化 C8：自 Enrollment resource 抽离）。

  收编自助取消链全部分支：lock_cancel_target（FOR UPDATE 锁读报名截止 /
  开课时间，防并发改期跨线）、claim_cancellable CAS（pending /
  payment_pending / confirmed 三占位态 → cancelled，RETURNING capacity_seq）、
  release_capacity 名额释放、Order.void_pending_for_enrollment 作废待付单、
  退款资格双锚判定（押金单 = 报名截止前 #587；定价单 = 活动开始前 #543，
  starts_at 缺失 fail-closed 不退）、after_action 退款入队
  （enqueue_self_cancel_refunds → RefundCommencement.commence，失败
  Ash.DataLayer.rollback 保对外错误形状——不留「已取消但钱未退」半态）。

  与 Cgc2046.Admission.Enrollment resource 的分工：resource 保留 DSL 壳、
  错误表（#241 契约单源）、多流共享 helper（add_domain_error /
  release_capacity / before_deadline?——后者与 create 路径的
  lock_qualification_target 共用）与对外端口。

  用法（resource DSL 直引，行为与抽离前逐字节一致）：

      Ash.Changeset.before_action(changeset, &Cgc2046.Admission.Enrollment.CancelFlow.prepare_cancel/1)
      Ash.Changeset.after_action(changeset, fn cs, enrollment ->
        Cgc2046.Admission.Enrollment.CancelFlow.enqueue_self_cancel_refunds(cs, enrollment)
      end)
  """

  require Ash.Query

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.ApprovalClaim

  @doc false
  def prepare_cancel(changeset) do
    with {:ok, event} <- lock_cancel_target(changeset.data.event_id, changeset.data.course_id),
         now = DateTime.utc_now(),
         {:ok, capacity_target} <- claim_cancellable(changeset.data.id, now),
         :ok <- Enrollment.release_capacity(capacity_target),
         {:ok, _voided} <-
           Cgc2046.Payments.Order.void_pending_for_enrollment(
             changeset.data.id,
             "enrollment_cancelled"
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :cancelled)
      |> Ash.Changeset.force_change_attribute(:cancelled_at, now)
      # 退款资格双锚（#543）：押金单 = 报名截止前（#587）；定价单 = 活动开始前
      # （条款 5.2「活动开始前全额退」）。锚点在锁后读钟一次锁定，避免锁等待
      # 期间跨线。starts_at 缺失（畸形数据）→ false（fail-closed 不退）。
      |> Ash.Changeset.put_context(
        :self_cancel_before_deadline,
        Enrollment.before_deadline?(event, now)
      )
      |> Ash.Changeset.put_context(
        :self_cancel_before_starts_at,
        before_starts_at?(event, now)
      )
    else
      {:error, reason} -> Enrollment.add_domain_error(changeset, reason)
    end
  end

  @doc false
  def enqueue_self_cancel_refunds(changeset, enrollment) do
    # #543：自助取消退款不再只认押金单——按订单口径分派锚点（押金单截止前 /
    # 定价单开始前全额退）。免费/免缴报名无活跃单，查询自然落空。
    orders =
      Cgc2046.Payments.Order
      |> Ash.Query.filter(
        enrollment_id == ^enrollment.id and
          status in [:paid, :refunding, :refund_failed]
      )
      |> Ash.read!(authorize?: false, tenant: enrollment.workspace_id)

    case orders do
      [order] ->
        if self_cancel_refund_eligible?(changeset, order) do
          commence_order_refund(order, enrollment)
        else
          {:ok, enrollment}
        end

      [] ->
        {:ok, enrollment}

      # 同一报名多条活跃单违反 unique_active_order 不变量（跨口径）：上抛回滚
      # 取消，不留「已取消但钱未退」的半态（after_action 的 {:error, _} 会提交）。
      _ ->
        raise "multiple active orders for enrollment #{enrollment.id}"
    end
  end

  defp commence_order_refund(order, enrollment) do
    # 退款发起单一入口（#845）：分类与竞态收敛在 RefundCommencement；入队由
    # Order action 的 after_action 承担（同事务恰好一次）。失败必须回滚事务：
    # after_action 返回 `{:error, _}` 会**提交**（`transaction_rollback_on_error?`
    # 未设），那样会留下「报名已取消、押金单仍 paid/refunding 且无退款 job」
    # 的静默吞钱（U6/KTD6 纪律）——用 Ash.DataLayer.rollback 回滚且保持对外
    # `{:error, …}` 形状（raise 会被 AshGraphql 降级成 something_went_wrong，
    # code 丢失，R2 阻断 2）。
    case Cgc2046.Payments.RefundCommencement.commence(order, eligible: [:paid, :refund_failed]) do
      {:ok, _tag} ->
        {:ok, enrollment}

      # R1-#1 修复后本分支可达：重读可能读到 forfeited（no-show 结算抢先）等
      # 不可发起状态——与「截止前/开始前取消应全退」冲突，fail-closed 回滚
      # 取消，绝不静默留钱。
      {:error, {:ineligible, status}} ->
        Ash.DataLayer.rollback(enrollment, {:ineligible, status})

      # 竞态重读仍未收敛 / DB 故障：回滚取消。错误原样透传（含 CAS 的
      # order_already_processed），与迁移前 cancel 的对外错误形状一致。
      {:error, reason} ->
        Ash.DataLayer.rollback(enrollment, reason)
    end
  end

  # #543：退款资格按订单口径选锚——押金单 = 报名截止前（#587 既定语义）；
  # 定价单 = 活动开始前（条款 5.2）。锚点布尔在 prepare_cancel 锁后统一判定。
  defp self_cancel_refund_eligible?(changeset, order) do
    case order.order_kind do
      :deposit -> Map.get(changeset.context, :self_cancel_before_deadline) == true
      :enrollment -> Map.get(changeset.context, :self_cancel_before_starts_at) == true
    end
  end

  # 定价单自助取消锚（#543）：活动开始前 = 可退。starts_at 缺失 → false
  # fail-closed（定价场 ⇒ starts_at 非空由 DB CHECK 兜底，此处只兜残差）。
  defp before_starts_at?(%{starts_at: nil}, _now), do: false

  defp before_starts_at?(%{starts_at: %NaiveDateTime{} = starts_at}, now),
    do: DateTime.compare(now, DateTime.from_naive!(starts_at, "Etc/UTC")) == :lt

  defp before_starts_at?(%{starts_at: starts_at}, now),
    do: DateTime.compare(now, starts_at) == :lt

  defp lock_cancel_target(event_id, nil) when not is_nil(event_id) do
    case Cgc2046.Repo.query(
           "SELECT registration_deadline, starts_at FROM events WHERE id = $1 FOR UPDATE",
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: [[deadline, starts_at]]}} ->
        {:ok, %{registration_deadline: deadline, starts_at: starts_at}}

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # course 无报名截止概念（恒 nil），但定价单退款锚 = 开课时间（#543）——与
  # event 同构锁读 starts_at（锁行防并发改期跨线）。
  defp lock_cancel_target(nil, course_id) when not is_nil(course_id) do
    case Cgc2046.Repo.query(
           "SELECT starts_at FROM courses WHERE id = $1 FOR UPDATE",
           [Cgc2046.Repo.uuid!(course_id)]
         ) do
      {:ok, %{rows: [[starts_at]]}} ->
        {:ok, %{registration_deadline: nil, starts_at: starts_at}}

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp lock_cancel_target(nil, nil), do: {:error, :target_not_found}

  defp lock_cancel_target(_event_id, _course_id), do: {:error, :target_not_found}

  defp claim_cancellable(id, now) do
    # payment_pending 与 confirmed 同为已占位窗口——取消必须释放名额（KTD6-4）。
    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：多状态 IN +
    # RETURNING 回读 capacity_seq/event_id/course_id（0 行 → :not_claimed →
    # :already_processed；返回值的容量目标分派留调用方，D3）。
    case ApprovalClaim.claim(%{id: id},
           table: :enrollments,
           from: [:pending, :payment_pending, :confirmed],
           set: [status: "cancelled", cancelled_at: {:arg, :now}],
           returning: [:capacity_seq, :event_id, :course_id],
           now: now
         ) do
      {:ok, %{capacity_seq: nil, event_id: _event_id, course_id: _course_id}} ->
        {:ok, nil}

      {:ok, %{capacity_seq: _capacity_seq, event_id: event_id, course_id: nil}}
      when not is_nil(event_id) ->
        {:ok, {:event, Ecto.UUID.load!(event_id)}}

      {:ok, %{capacity_seq: _capacity_seq, event_id: nil, course_id: course_id}}
      when not is_nil(course_id) ->
        {:ok, {:course, Ecto.UUID.load!(course_id)}}

      {:ok, _unexpected} ->
        {:error, :capacity_counter_invalid}

      {:error, :not_claimed} ->
        {:error, :already_processed}

      {:error, {:database, _} = reason} ->
        {:error, reason}
    end
  end
end
