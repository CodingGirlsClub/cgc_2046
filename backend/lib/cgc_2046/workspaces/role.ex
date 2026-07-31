defmodule Cgc2046.Workspaces.Role do
  @moduledoc """
  Role(租户内实体,T04):Workspace 内的角色。

  角色是数据库实体而非写死枚举,`permissions` 数组即该角色的权限集
  (spec §4 权限矩阵),支持扩展。新 Workspace 由
  `Cgc2046.Rbac.initialize_workspace!/1` 初始化默认模板
  (Owner/Admin/Tutor/Volunteer/Learner),见 docs/spec §4。

  授权:
  - 读: 成员或平台管理员(MemberOfWorkspace)
  - 创建/删除: 需租户权限 `member:manage`(Owner/Admin)
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true

    attribute :description, :string,
      allow_nil?: true,
      public?: true

    attribute :permissions, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      public?: true
  end

  identities do
    identity :unique_name_per_workspace, [:workspace_id, :name]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :permissions]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type([:create, :destroy]) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "member:manage"}
      forbid_if always()
    end
  end

  postgres do
    table "roles"
    repo Cgc2046.Repo
  end
end
