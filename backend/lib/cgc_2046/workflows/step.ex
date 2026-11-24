defmodule Cgc2046.Workflows.Step do
  @moduledoc """
  Workflow 步骤资源（Slice C #34/#36）。

  领域模型：Step 是独立资源（ER 有 STEP 实体 + FK），
  非 node_def 内嵌——这样 StepRole 通过 step_id 直接关联，#38 授权查询高效。

  ## 步骤类型

  - `:manual` 人工步骤——纯数据线性门控，等待外部信号（`"workflow.<step_key>"`）放行

  （注：历史 `:auto` / `:gate` / `:sub_workflow` 类型已退役；`action` 与
  `sub_definition_id` 字段保留作滚动部署与历史数据兼容列。）
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Workflows

  @type_values [:manual]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:definition_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "所属 WorkflowDefinition ID"
    )

    attribute(:step_key, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "步骤标识（node_def 拓扑引用的 key，如 \"outline_design\"）"
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "步骤标题（展示用）"
    )

    attribute(:type, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @type_values],
      description: "步骤类型：当前仅支持 manual（人工门控）"
    )

    # 历史兼容列（已退役的 auto/gate handler 模块名，保留列以兼容滚动部署）
    attribute(:action, :string,
      public?: true,
      writable?: true,
      description: "历史兼容列（已退役的自动步骤 handler 模块名，manual 步骤可空）"
    )

    # R2 裁决（2026-08-16）：agent_id 删除——形态 X（BYO，ADR-0001）下平台不建模
    # Agent 实体，原列为无拍板的悬空引用（DRIFT-REPORT L1-1/R2）。

    # 历史兼容列（已退役的 sub_workflow 子定义引用，保留列以兼容滚动部署）
    attribute(:sub_definition_id, :uuid,
      public?: true,
      writable?: true,
      description: "历史兼容列（已退役的子 workflow 定义 ID，manual 步骤可空）"
    )

    # 该步骤输入参数 schema
    attribute(:input_schema, :map,
      public?: true,
      writable?: true,
      description: "该步骤输入参数 schema"
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
    belongs_to(:definition, Cgc2046.Workflows.WorkflowDefinition,
      source_attribute: :definition_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    has_many(:step_roles, Cgc2046.Workflows.StepRole,
      destination_attribute: :step_id,
      description: "可执行本步的角色（#38 授权）"
    )
  end

  actions do
    default_accept([
      :definition_id,
      :step_key,
      :title,
      :type,
      :action,
      :sub_definition_id,
      :input_schema
    ])

    defaults([:read, :destroy])

    create :create do
      description("创建步骤定义")
      primary?(true)
    end

    update :update do
      description("更新步骤定义")
      primary?(true)
    end
  end

  identities do
    # 同一 definition 下 step_key 唯一
    identity(:unique_step_key_per_definition, [:definition_id, :step_key])
  end

  postgres do
    table("workflow_steps")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 definition → workspace → memberships 路径，仅成员或平台管理员
    policy action_type(:read) do
      authorize_if(
        {Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]}
      )

      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:workflow_step)
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:workflows)
    table_columns([:id, :definition_id, :step_key, :title, :type, :action, :inserted_at])
  end
end
