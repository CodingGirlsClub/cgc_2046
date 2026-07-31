defmodule Cgc2046.Workspaces.AgentRole do
  @moduledoc """
  AgentRole(租户内实体,T05):公共 Agent 的独立使用授权关联。

  `role_id` 引用租户内 Role;公共 Agent 声明"哪些角色可直接用我"
  (Workflow 之外独立使用,见 docs/领域模型定稿.md §3.3)。独立使用授权 =
  成员角色集 ∩ AgentRole 角色集 交集非空。

  读 = 成员;创建/删除 = 需 `agent:public:edit`(Owner/Admin/Tutor)。
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

    belongs_to :agent, Cgc2046.Workspaces.Agent,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :role, Cgc2046.Workspaces.Role,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_agent_role, [:agent_id, :role_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:agent_id, :role_id]

      change before_action(fn changeset, context ->
               if context.authorize? != false do
                 Cgc2046.Rbac.forbid_changeset(changeset, context.actor, "agent:public:edit",
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
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "agent:public:edit"}
      forbid_if always()
    end
  end

  postgres do
    table "agent_roles"
    repo Cgc2046.Repo
  end
end
