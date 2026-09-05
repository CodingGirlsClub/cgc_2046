defmodule Cgc2046.Workflows.StepRole do
  @moduledoc """
  Step 执行角色关联资源（Slice C #38）。

  领域模型：STEP_ROLE 是 Step 与 Role 的多对多关联表。
  授权判定 = actor 角色集合 ∩ step 执行角色集合，命中即放行（多角色并集）。

  ## ADR-0003 纪律

  授权在 Step 执行的 prepare 阶段校验（外置为 before_step 钩子），不内建审批状态机。
  自动/gate/sub_workflow 步骤由引擎执行不授权；manual 步骤授权信号发起人（领域模型定稿 §4.3）。

  v1（#34 阶段）先建资源骨架，授权判定逻辑在 #38 实现。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Workflows

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:step_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "关联的 Step ID"
    )

    attribute(:role_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "关联的 Role ID（可执行该 step 的角色）"
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
    belongs_to(:step, Cgc2046.Workflows.Step,
      source_attribute: :step_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:role, Cgc2046.Accounts.Role,
      source_attribute: :role_id,
      destination_attribute: :id,
      allow_nil?: false
    )
  end

  actions do
    default_accept([:step_id, :role_id])
    defaults([:read, :destroy])

    create :create do
      description("为 step 关联可执行角色")
      primary?(true)
    end
  end

  identities do
    # 同一 step + role 组合唯一
    identity(:unique_step_role, [:step_id, :role_id])
  end

  postgres do
    table("workflow_step_roles")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 step → definition → workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if(
        {Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia,
         path: [:step, :definition, :workspace]}
      )

      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:workflow_step_role)
  end

  admin do
    # #113 ops 面优化：导航分组
    resource_group(:workflows)
  end
end
