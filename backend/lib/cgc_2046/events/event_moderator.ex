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
  end

  actions do
    defaults([:read])

    create :assign do
      accept([:workspace_id, :event_id, :user_id, :assigned_by, :assigned_at])

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

  # LogAdminAction 契约（public 远程捕获）：target = 活动，metadata 带被指派/被撤者
  def log_event_id(_changeset, record), do: record.event_id

  def log_metadata(_changeset, record) do
    %{"user_id" => record.user_id, "event_id" => record.event_id}
  end
end
