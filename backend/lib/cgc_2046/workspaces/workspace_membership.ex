defmodule Cgc2046.Workspaces.WorkspaceMembership do
  @moduledoc """
  WorkspaceMembership(租户资源,T03 最小骨架)。

  T03 仅落地 attribute 多租户隔离载体:按 `workspace_id` 隔离,查询/写入
  必须显式 set_tenant(见 docs/multitenancy-调研.md 决策点)。角色/默认
  模板/多角色并集由 T04(成员与角色)扩展。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      public?: true

    belongs_to :user, Cgc2046.Accounts.User,
      attribute_type: :uuid,
      public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:user_id]
    end
  end

  postgres do
    table "workspace_memberships"
    repo Cgc2046.Repo
  end
end
