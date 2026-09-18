defmodule Cgc2046.Events.EventModerator do
  @moduledoc """
  Event 级主理人关联；目标用户须为目标 Workspace 成员（#558 / #542 决策 A1：
  指派前校验成员资格，非成员报错引导先邀请入台——「主理人不是成员」的
  KD7 原始前提已修订）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Events

  attributes do
    uuid_primary_key(:id)
    attribute(:workspace_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:event_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:user_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:assigned_by, :uuid, public?: true, writable?: true)

    attribute(:assigned_at, :utc_datetime,
      allow_nil?: false,
      default: &DateTime.utc_now/0,
      public?: true,
      writable?: true
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:event, Cgc2046.Events.Event,
      source_attribute: :event_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:user, Cgc2046.Accounts.User,
      source_attribute: :user_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    # #537 assigned_by 回显平铺用（复用现有列，无新属性）
    belongs_to(:assigned_by_user, Cgc2046.Accounts.User,
      source_attribute: :assigned_by,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  calculations do
    # #537 回显平铺（BypassReads 平铺先例，同 WorkspaceMembership.user_display_name）：
    # 嵌套 user 加载会被 User read policy 滤空（only_me），平铺 LEFT JOIN 绕过；
    # 安全契约与 quirk 知识见 BypassReads（旁路读取面）moduledoc。
    calculate(:user_display_name, :string, expr(user.display_name),
      public?: true,
      description: "主理人显示名（平铺自 user 关系，#537；回显 fallback 链首选）"
    )

    calculate(:assigned_by_display_name, :string, expr(assigned_by_user.display_name),
      public?: true,
      description: "指派人显示名（平铺自 assigned_by_user 关系，#537；assigned_by 为空时为 null）"
    )

    calculate(
      :user_member_number,
      :string,
      {Cgc2046.Events.Calculations.MemberNumberOf, field: :user_id},
      public?: true,
      description: "主理人成员编号（CGC-XXXXXX，由 user_id 现算，#537；恒非空）"
    )

    calculate(
      :assigned_by_member_number,
      :string,
      {Cgc2046.Events.Calculations.MemberNumberOf, field: :assigned_by},
      public?: true,
      description: "指派人成员编号（CGC-XXXXXX，由 assigned_by 现算，#537；assigned_by 为空时为 null）"
    )
  end

  actions do
    defaults([:read])

    create :assign do
      accept([:workspace_id, :event_id, :user_id, :assigned_by, :assigned_at])

      # 重复指派撞 identity 唯一索引 → 稳定业务错误（#611）
      error_handler({__MODULE__, :handle_write_error, []})

      # 成员前提（#558）：资源写边界单点拦截，覆盖一切调用面
      validate({Cgc2046.Events.ModeratorMembershipValidation, []})

      # 治理留痕（同事务，attendance_check_in 同款 LogAdminAction 形状）
      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :event_moderator_assign,
         target_type: :event,
         target_id: &__MODULE__.log_event_id/2,
         metadata: &__MODULE__.log_metadata/2}
      )
    end

    destroy :remove do
      primary?(true)
      accept([])

      # LogAdminAction 是 after_action（非原子）——声明回落到带原数据的常规路径
      require_atomic?(false)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :event_moderator_remove,
         target_type: :event,
         target_id: &__MODULE__.log_event_id/2,
         metadata: &__MODULE__.log_metadata/2}
      )
    end
  end

  identities do
    identity(:unique_event_user, [:event_id, :user_id])
  end

  postgres do
    table("event_moderators")
    repo(Cgc2046.Repo)

    # #537：assigned_by 的 FK 契约显式化——DB 侧 20260913155651 手写建表即
    # SET NULL（用户删除 → 指派人置空，行保留），此处对齐而非新引入；
    # snapshot 链同步（CI --check 门禁，PR #721 红根因）。
    references do
      reference(:assigned_by_user, on_delete: :nilify)

      # #724：event_id / user_id 的 ON DELETE CASCADE 显式化——对齐
      # 20260913155651 的 delete_all（DB 实测 confdeltype=c）；无 DDL。
      reference(:event, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  # create error_handler（#611）：重复指派撞
  # `event_moderators_unique_event_user_index` → `event_moderator_already_assigned`。
  # `Moderators.assign/4`（GraphQL `assign_event_moderator` 与 MCP 工具共用）无 identity
  # 预查，故这是可达路径；成员前提（ModeratorMembershipValidation）是另一条独立校验，
  # 两者 code 不同源不互相顶替。
  #
  # 按约束名分派（本表日后加 identity 时不误归因）；非 unique 冲突原样上抛（fail-closed）。
  # 幂等语义 `Moderators.ensure_assigned/2` 按本 code 判定，不再匹配错误原文。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
         Cgc2046.Errors.ConstraintConflict.constraint_named?(
           error,
           "event_moderators_unique_event_user_index"
         ) do
      Cgc2046.Errors.BusinessError.exception(
        message: "this user is already a moderator of the event",
        code: "event_moderator_already_assigned",
        fields: [:user_id]
      )
    else
      error
    end
  end

  # LogAdminAction 契约（public 远程捕获）：target = 活动，metadata 带被指派/被撤者
  def log_event_id(_changeset, record), do: record.event_id

  def log_metadata(_changeset, record) do
    %{"user_id" => record.user_id, "event_id" => record.event_id}
  end
end
