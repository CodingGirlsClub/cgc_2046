defmodule Cgc2046.Workspaces.StepRole do
  @moduledoc """
  StepRole(租户内实体,T05):Step 的执行角色关联(Step 允许角色集)。

  `role_id` 引用租户内 Role;一个 Step 可声明多个可执行角色。执行授权 =
  成员角色集 ∩ Step 允许角色集 交集非空(`Rbac.role_intersection?/3`,
  见 Cgc2046.Workspaces.Step.execute)。

  读 = 成员;创建/删除 = 需 `workflow:create`(部署者配置 Step 角色)。
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :step, Cgc2046.Workspaces.Step,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :role, Cgc2046.Workspaces.Role,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_step_role, [:step_id, :role_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:step_id, :role_id]

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "workflow:create",
                   tenant: context.tenant
                 )
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

    policy action_type([:create, :destroy]) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "workflow:create"}
      forbid_if always()
    end
  end

  postgres do
    table "step_roles"
    repo Cgc2046.Repo
  end
end
