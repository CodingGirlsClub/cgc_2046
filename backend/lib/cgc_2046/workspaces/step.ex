defmodule Cgc2046.Workspaces.Step do
  @moduledoc """
  Step(租户内实体,T05):Workflow 的步骤,是授权最小单元(见
  docs/领域模型定稿.md §3.2)。

  每个 Step 声明哪些角色可执行(`roles` 多对多,经 StepRole 关联)。
  **执行授权 = 成员角色集 ∩ Step 允许角色集 交集非空**
  (`Rbac.role_intersection?/3`);顺序解锁/状态机随 M1 落地。

  读 = 成员;创建 = 需 `workflow:create`(部署者建 Step)。
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

    attribute :title, :string,
      allow_nil?: false,
      public?: true

    attribute :position, :integer,
      allow_nil?: false,
      public?: true

    attribute :type, :string,
      allow_nil?: true,
      public?: true

    attribute :agent_hint, :string,
      allow_nil?: true,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Cgc2046.Workspaces.Workspace,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    belongs_to :workflow, Cgc2046.Workspaces.Workflow,
      attribute_type: :uuid,
      allow_nil?: false,
      public?: true

    has_many :step_roles, Cgc2046.Workspaces.StepRole,
      destination_attribute: :step_id

    many_to_many :roles, Cgc2046.Workspaces.Role,
      through: Cgc2046.Workspaces.StepRole,
      source_attribute_on_join_resource: :step_id,
      destination_attribute_on_join_resource: :role_id
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :position, :type, :agent_hint, :workflow_id]

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

    read :execute do
      primary? false
      argument :step_id, :uuid, allow_nil?: false

      manual fn query, _data_layer_query, context ->
        step_id = Ash.Query.get_argument(query, :step_id)

        step =
          Ash.get!(__MODULE__, step_id,
            tenant: context.tenant,
            actor: context.actor,
            load: [:roles],
            authorize?: true
          )

        allowed_role_ids = Enum.map(step.roles, & &1.id)

        if Cgc2046.Rbac.role_intersection?(context.actor, context.tenant, allowed_role_ids) do
          {:ok, [step]}
        else
          {:error, Ash.Error.Forbidden.exception([])}
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action(:execute) do
      authorize_if Cgc2046.Rbac.Checks.MemberOfWorkspace
      forbid_if always()
    end

    policy action_type(:create) do
      authorize_if {Cgc2046.Rbac.Checks.HasPermission, permission: "workflow:create"}
      forbid_if always()
    end
  end

  postgres do
    table "steps"
    repo Cgc2046.Repo
  end
end
