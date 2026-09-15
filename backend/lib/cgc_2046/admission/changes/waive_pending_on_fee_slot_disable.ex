defmodule Cgc2046.Admission.Changes.WaivePendingOnFeeSlotDisable do
  @moduledoc """
  R9 关闭收费批量免费确认（organizer-payment U3，KTD4）+ 押金关闭同款（KTD1/KTD3）。

  Event/Course 的 update 动作检测**计费槽被关闭**（`pricing_enabled` 或
  `deposit_enabled` true→false；course 无押金列，等价于原判据）时，after_action
  内（同事务）对该 offering 的全部 payment_pending 报名逐条复用免缴三元组：
  CAS 转确认 + 作废待付单 + 免缴审计行 + 补发 completed 信号（实现全部收敛在
  `Enrollment.waive_pending_for_offering/4`）。任一笔失败上抛，整个 update
  回滚——翻转与批量转换原子生效，以发起组织者为操作者。

  竞态窗口（KTD4）：批量执行前已落账者 CAS num_rows=0 跳过、保持已付；批量
  后的迟到扣款由落账 worker 按免缴审计行/作废单自动原路退回
  （payment_settlement_worker 兜底，AE2/AE3 语义）。

  用法（fn 约束同 SignalEmitter：本模块自身即 change，opts 字面量安全）：

      change {Cgc2046.Admission.Changes.WaivePendingOnFeeSlotDisable, kind: :event}

  opts：

  - `kind`：`:event | :course`——报名筛选与调用方签名对齐。
  """

  use Ash.Resource.Change

  alias Cgc2046.Admission.Enrollment

  @impl true
  def change(changeset, opts, _context) do
    kind = Keyword.fetch!(opts, :kind)

    if fee_slot_being_disabled?(changeset) do
      Ash.Changeset.after_action(changeset, fn cs, updated ->
        actor = get_in(cs.context, [:private, :actor])

        case Enrollment.waive_pending_for_offering(kind, updated.id, actor, updated.workspace_id) do
          :ok ->
            {:ok, updated}

          {:error, :actor_required} ->
            {:error,
             Cgc2046.Errors.BusinessError.exception(
               message: "disabling pricing with pending enrollments requires an actor",
               code: "pricing_disable_actor_required",
               fields: [:pricing_enabled]
             )}

          {:error, :batch_waive_limit_exceeded} ->
            {:error,
             Cgc2046.Errors.BusinessError.exception(
               message:
                 "too many pending enrollments to waive in one transaction (limit 200); cancel the offering instead",
               code: "pricing_disable_batch_limit",
               fields: [:pricing_enabled]
             )}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      changeset
    end
  end

  # 计费槽关闭：定价或押金任一 true→false（关押金与关定价语义相同——已报名的
  # payment_pending 不该因「不收费了」而等过期释放名额）
  defp fee_slot_being_disabled?(changeset) do
    disabled?(changeset, :pricing_enabled) or disabled?(changeset, :deposit_enabled)
  end

  defp disabled?(changeset, attribute) do
    Ash.Changeset.changing_attribute?(changeset, attribute) and
      Ash.Changeset.get_data(changeset, attribute) == true and
      Ash.Changeset.get_attribute(changeset, attribute) == false
  end
end
