defmodule Cgc2046.Accounts.AdminActionLog do
  @moduledoc """
  admin 治理操作留痕资源（#116 / R10a）。

  每条平台治理操作落一行：谁（actor）/ 动作（action）/ 目标（target）/ 结果（result）/
  时间（inserted_at）。区别于运营审计（Mcp.ToolCallLog 等四资源）——本资源只覆盖
  治理操作：workspace 直接创建、工作台创建申请审批（approve/reject）、
  platform_admin 提升/降级、pending-owner 重指派与邀请取消（#114）。

  写入路径：治理 action 的挂接统一经 `Cgc2046.Accounts.Changes.LogAdminAction` 注册（声明式
  change 或函数式 `log/3`，见其 moduledoc），同事务落库（authorize?: false），失败
  上抛回滚治理操作本身（fail-closed，不留半态，对齐 workspace create 角色 seed 范式）。
  读路径：仅 platform_admin（/admin/audit 治理操作 tab + AshAdmin /ops/admin）。

  v1 只记录成功操作（result 恒 :success）：失败操作在条件 UPDATE/状态守卫阶段被拒、
  事务回滚，同事务内无法落日志；result 列保留 :failure 枚举供未来扩展。
  metadata 落 DB 备用（slug/email/rejection_reason 等展示快照），v1 不经 GraphQL 暴露。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Accounts

  attributes do
    uuid_primary_key(:id)

    attribute(:actor_id, :uuid,
      allow_nil?: true,
      public?: true,
      description: "操作人（platform_admin）ID；nil = 系统/CLI（无 actor 调用）"
    )

    attribute(:action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :workspace_create,
          :application_approve,
          :application_reject,
          :admin_promote,
          :admin_demote,
          :owner_reassign,
          :owner_invitation_cancel,
          :waive_payment,
          # 缴费闭环 U9：退款治理动作（R15）
          :order_refund,
          :order_refund_retry,
          # #545：错没收人工救济（PlatformAdmin 专用，metadata 带必填 reason）
          :order_unforfeit,
          # advisory F-J：Event cancelled 批量退款（系统驱动无 actor，actor_id
          # = nil 与 CLI 系统动作同语义；每 event 一行，metadata 带批量计数）
          :event_cancel_batch_refund,
          # organizer-payment U2：Course cancelled 批量退款（R15，与 Event 同语义）
          :course_cancel_batch_refund,
          :initiative_rule_update,
          :initiative_create,
          :initiative_update,
          :initiative_open,
          :initiative_close,
          # #628 中止（与 :initiative_close 分叉：中止级联取消挂载场并全额退款）
          :initiative_cancel,
          # #628 级联批量（系统驱动无 actor，actor_id = nil；每 initiative 一行，
          # metadata 带取消场次数与跳过数。口径同 :event_cancel_batch_refund）
          :initiative_cancel_batch,
          :event_moderator_assign,
          :event_moderator_remove,
          # 押金制 U5/KTD4：主理人核销到场（每报名一行，metadata 带 event_id/method）
          :attendance_check_in,
          # 押金制 U8/KTD7：no-show 结算没收（系统驱动无 actor，每 event 一行，
          # metadata 带没收笔数/金额/order id 列表；deposit 押金单终态审计）
          :deposit_forfeit,
          # 押金制 U6/KTD6：核销即退（每笔押金退还一行，actor = 核销人，
          # target = 押金单）。规 13 资金动作爆发白名单**不**收录本 action
          # ——核销是主理人现场的正常高频动作，收录即告警风暴。
          :attendance_refund
        ]
      ],
      description: "治理动作类型"
    )

    attribute(:target_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :workspace,
          :workspace_application,
          :user,
          :enrollment,
          :order,
          :event,
          :course,
          :initiative
        ]
      ],
      description: "目标资源类型"
    )

    attribute(:target_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "目标资源 ID"
    )

    attribute(:result, :atom,
      allow_nil?: false,
      default: :success,
      public?: true,
      constraints: [one_of: [:success, :failure]],
      description: "操作结果（v1 仅 :success；:failure 保留扩展）"
    )

    attribute(:metadata, :map,
      allow_nil?: false,
      default: %{},
      description: "展示用快照（slug/email/rejection_reason 等；v1 不经 GraphQL 暴露）"
    )

    create_timestamp(:inserted_at)
  end

  postgres do
    table("admin_action_logs")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read])

    create :log do
      description("落一条治理操作留痕（系统内部使用，bypass policy 调用）")
      accept([:actor_id, :action, :target_type, :target_id, :result, :metadata])
    end
  end

  policies do
    # 系统写入：治理 action 的 after_action 以 authorize?: false 调用（同 ToolCallLog 范式）
    policy action(:log) do
      authorize_if(always())
    end

    # platform_admin 可读全部留痕（R10a）；非 admin default-deny
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  @doc """
  同事务落一条治理操作留痕（authorize?: false；供治理 action 的 after_action 调用）。
  返回 {:ok, record} / {:error, _}——调用方经 with 上抛，失败回滚治理操作本身（fail-closed）。
  """
  def log(attrs) do
    __MODULE__
    |> Ash.Changeset.for_create(:log, attrs)
    |> Ash.create(authorize?: false)
  end

  @doc """
  `log/1` 的 raise 型（写入失败即上抛 → 整事务回滚）。

  供 after_action 内站点使用：Ash 3.33 的 after_action 返回 `{:error, _}` 会**提交**
  事务（`transaction_rollback_on_error?` 未设），需要「留痕失败即回滚」的站点只能靠
  上抛（KTD6 核销即退的 `:attendance_refund` 留痕同款形状）。
  """
  def log!(attrs) do
    __MODULE__
    |> Ash.Changeset.for_create(:log, attrs)
    |> Ash.create!(authorize?: false)
  end
end
