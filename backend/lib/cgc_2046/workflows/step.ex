defmodule Cgc2046.Workflows.Step do
  @moduledoc """
  Workflow 步骤资源（Slice C #34/#36）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Step 是独立资源（ER 有 STEP 实体 + FK），
  非 node_def 内嵌——这样 StepRole 通过 step_id 直接关联，#38 授权查询高效。

  ## 四分类（#36，领域模型定稿 §4.3）

  - `:auto` 自动步骤——Jido Action（纯函数/可含副作用）
  - `:manual` 人工步骤——SignalMatch 门控等待外部信号
  - `:gate` 门控/分支——按 Fact 条件路由下游
  - `:sub_workflow` 子 workflow——嵌套 DAG（sub_definition_id 指向另一 WorkflowDefinition）

  ## ADR-0003 纪律

  - `action` 是模块名字符串，指向经 `StepHandlerRegistry` 注册的 handler 模块。
    引擎运行时解析 + 注册表白名单校验（#25：StepHandler behaviour 已删，
    无实现者，注册表是唯一授权面）。
  - 子 workflow 是 step type 的一种，不是核心原语（pi「不内建 sub-agents」同构）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  @type_values [:auto, :manual, :gate, :sub_workflow]

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
      description: "步骤类型：auto 自动 / manual 人工 / gate 门控 / sub_workflow 子 workflow"
    )

    # action 指向经 StepHandlerRegistry 注册的 handler 模块名（auto/gate 类型）；manual 可空（等信号，无 action）
    attribute(:action, :string,
      public?: true,
      writable?: true,
      description: "经 StepHandlerRegistry 注册的模块名（auto/gate）；manual 可空"
    )

    # 人工步骤使用的 Agent（领域模型定稿 ER §5.2）
    attribute(:agent_id, :uuid,
      public?: true,
      writable?: true,
      description: "人工步骤使用的 Agent ID（manual 类型，其余可空）"
    )

    # 子 workflow 指向另一 WorkflowDefinition（type=sub_workflow）
    attribute(:sub_definition_id, :uuid,
      public?: true,
      writable?: true,
      description: "子 workflow 指向的 WorkflowDefinition ID（sub_workflow 类型）"
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
      :agent_id,
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
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
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
