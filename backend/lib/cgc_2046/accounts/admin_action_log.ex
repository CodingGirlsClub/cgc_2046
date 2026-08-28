defmodule Cgc2046.Accounts.AdminActionLog do
  @moduledoc """
  admin 治理操作留痕资源（#116 / R10a）。

  每条平台治理操作落一行：谁（actor）/ 动作（action）/ 目标（target）/ 结果（result）/
  时间（inserted_at）。区别于运营审计（Mcp.ToolCallLog 等四资源）——本资源只覆盖
  治理操作：workspace 直接创建、工作台创建申请审批（approve/reject）、
  platform_admin 提升/降级、pending-owner 重指派与邀请取消（#114）。

  写入路径：治理 action 的挂接统一经 `Cgc2046.Changes.LogAdminAction` 注册（声明式
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
          # advisory F-J：Event cancelled 批量退款（系统驱动无 actor，actor_id
          # = nil 与 CLI 系统动作同语义；每 event 一行，metadata 带批量计数）
          :event_cancel_batch_refund,
          # organizer-payment U2：Course cancelled 批量退款（R15，与 Event 同语义）
          :course_cancel_batch_refund
        ]
      ],
      description: "治理动作类型"
    )

    attribute(:target_type, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [:workspace, :workspace_application, :user, :enrollment, :order, :event, :course]
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
end
