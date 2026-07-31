defmodule Cgc2046.Workspaces.Profile do
  @moduledoc """
  Profile(租户内实体,T06):成员公开资料。

  字段:avatar_url(头像)、bio(简介)、tags(标签)、portfolio(作品展示)。
  每个成员在每个 workspace 至多一条(唯一约束 `unique_user_per_workspace`)。

  授权(spec §12):
  - 读 = 成员可见(MemberOfWorkspace,租户内可见)
  - 创建 = 成员(自动绑定 actor 为本人)
  - 更新/删除 = 本人(user_id == actor.id)且为成员
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid,
      allow_nil?: false,
      public?: true

    attribute :avatar_url, :string,
      allow_nil?: true,
      public?: true

    attribute :bio, :string,
      allow_nil?: true,
      public?: true

    attribute :tags, {:array, :string},
      allow_nil?: true,
      default: [],
      public?: true

    attribute :portfolio, {:array, :string},
      allow_nil?: true,
      default: [],
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :user, Cgc2046.Accounts.User,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_user_per_workspace, [:workspace_id, :user_id]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:avatar_url, :bio, :tags, :portfolio]

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          changeset
          |> Ash.Changeset.change_attribute(:user_id, context.actor.id)
        else
          changeset
        end
      end)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:avatar_url, :bio, :tags, :portfolio]

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          ensure_self(changeset, context.actor)
        else
          changeset
        end
      end)
    end

    destroy :destroy do
      require_atomic? false

      change before_action(fn changeset, context ->
        if context.authorize? != false do
          ensure_self(changeset, context.actor)
        else
          changeset
        end
      end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end
  end

  postgres do
    table "profiles"
    repo Cgc2046.Repo
  end

  # 仅本人可更新/删除自己的 Profile(他人 profile 对写 action 不可见 → 404)
  defp ensure_self(changeset, actor) do
    if Ash.Changeset.get_attribute(changeset, :user_id) == actor.id do
      changeset
    else
      Ash.Changeset.add_error(changeset, Ash.Error.Forbidden.exception([]))
    end
  end
end
