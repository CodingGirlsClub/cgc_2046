defmodule Cgc2046.Workflows.WorkflowDefinition do
  @moduledoc """
  Workflow 蓝图资源（Slice C #34）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：WorkflowDefinition 是声明式 DAG 蓝图，
  带版本管理；改定义不影响已开始 run（D-A2，已开始 run 持当时 published 版本）。

  ## ADR-0003 纪律

  - **蓝图是数据不是代码**：node_def 只存执行拓扑（步骤顺序/依赖），Step 字段（type/agent_id/
    sub_definition_id）独立存于 Step 资源。运行时由引擎读取驱动执行，改定义不改代码。
  - **核心是协议不是框架**：本资源只描述「做什么步骤、什么顺序、什么类型」，不内建审批/MCP/审计
    逻辑——这些通过 Step 的 action（指向实现 StepHandler behaviour 的模块）外置。

  ## 生命周期/版本（#34 acceptance）

      draft ──publish──► published ──archive──► archived
        ▲                   │
        │ new_version       │
        └─── draft(v+1) ◄───┘

  已 published 的定义可 new_version 出 draft 修订，改完再 publish。已发布版本不可修改，
  已开始 WorkflowRun 绑定 definition_version，不随后续版本变动（D-A2）。

  ## 多租户

  multitenancy attribute :workspace_id，与 accounts 资源一致；每 workspace = 一个 Jido partition
  （ADR-0002 决策 6）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  # WorkflowDefinition.type 全 6 枚举（领域模型定稿 ER §5.2 权威源）
  @type_values [
    :platform_ops,
    :learning,
    :enrollment,
    :sponsorship,
    :speaker_invitation,
    :research
  ]
  @status_values [:draft, :published, :archived]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "蓝图名称（租户内可读）"
    )

    attribute(:type, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @type_values],
      description:
        "workflow 类型：platform_ops 平台运营 / learning 学习 / enrollment 报名 / " <>
          "sponsorship 赞助 / speaker_invitation 邀请讲者 / research 教研"
    )

    attribute(:version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      writable?: false,
      description: "版本号，单调递增；new_version 出 v+1（#34）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "生命周期：draft 草稿 / published 已发布 / archived 已归档"
    )

    attribute(:input_schema, :map,
      public?: true,
      writable?: true,
      description: "workflow 输入参数 schema"
    )

    attribute(:node_def, :map,
      public?: true,
      writable?: true,
      description: "执行拓扑（步骤顺序/依赖），声明式数据；Step 字段独立存于 Step 资源"
    )

    # F7 方案 A：审批超时（领域模型定稿 ER §5.2，默认 7 天 = 604800 秒，nil = 无超时）
    attribute(:approval_timeout, :integer,
      public?: true,
      writable?: true,
      description: "人工步骤审批超时秒数（默认 7 天 604800，nil = 无超时）"
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
    # belongs_to workspace：供 Step/StepRole 经 [:definition, :workspace, :memberships, :user]
    # 路径做成员授权（H3）；也供产出展示页 #40 读 workspace 信息
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    has_many(:steps, Cgc2046.Workflows.Step,
      destination_attribute: :definition_id,
      description: "workflow 的步骤定义（独立资源，#36 四分类）"
    )
  end

  actions do
    default_accept([:name, :type, :input_schema, :node_def, :approval_timeout])

    create :create do
      description("创建 workflow 蓝图（默认 status=draft, version=1）")
      accept([:name, :type, :input_schema, :node_def, :approval_timeout])

      change(set_attribute(:status, :draft))
      change(set_attribute(:version, 1))
    end

    # publish: draft → published；已 archived 不可 publish
    update :publish do
      description("发布蓝图：draft → published")
      require_atomic?(false)

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :draft -> Ash.Changeset.force_change_attribute(changeset, :status, :published)
          status -> Ash.Changeset.add_error(changeset, "cannot publish from status=#{status}")
        end
      end)
    end

    # archive: published → archived；archived 不可再 publish
    update :archive do
      description("归档蓝图：published → archived")
      require_atomic?(false)

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :published -> Ash.Changeset.force_change_attribute(changeset, :status, :archived)
          status -> Ash.Changeset.add_error(changeset, "cannot archive from status=#{status}")
        end
      end)
    end

    # new_version: 基于 published 定义创建 draft 新版本（version + 1）
    create :new_version do
      description("基于已发布定义创建新 draft 版本")

      # 字段全部从 source 继承，调用方不传（accept 清空，仅 source_definition_id argument）
      accept([])

      argument(:source_definition_id, :uuid,
        allow_nil?: false,
        description: "源定义 ID（须为本租户内 published 定义）"
      )

      change(fn changeset, _context ->
        source_id = Ash.Changeset.get_argument(changeset, :source_definition_id)

        # 当前租户 = 目标 workspace_id（调用方必传 tenant）。用它限定 source 查询范围，
        # 杜绝跨租户读（H2：global?(true) 下不传 tenant 的 Ash.get 会全表读）。
        tenant = changeset.tenant

        if is_nil(tenant) do
          Ash.Changeset.add_error(changeset, "new_version requires a tenant (workspace_id)")
        else
          case Ash.get(Cgc2046.Workflows.WorkflowDefinition, source_id,
                 tenant: tenant,
                 authorize?: false
               ) do
            {:ok, source} when source.status == :published ->
              # 双保险：即便 tenant 参数失效，校验 source 归属当前 workspace
              if source.workspace_id != tenant do
                Ash.Changeset.add_error(
                  changeset,
                  "source definition #{source_id} belongs to a different workspace"
                )
              else
                changeset
                |> Ash.Changeset.force_change_attribute(:version, source.version + 1)
                |> Ash.Changeset.force_change_attribute(:status, :draft)
                |> Ash.Changeset.change_attribute(:name, source.name)
                |> Ash.Changeset.change_attribute(:type, source.type)
                |> Ash.Changeset.change_attribute(:input_schema, source.input_schema)
                |> Ash.Changeset.change_attribute(:node_def, source.node_def)
                |> Ash.Changeset.change_attribute(:approval_timeout, source.approval_timeout)
              end

            {:ok, source} ->
              Ash.Changeset.add_error(
                changeset,
                "source definition #{source_id} status=#{source.status}, must be published"
              )

            {:error, _} ->
              Ash.Changeset.add_error(changeset, "source definition #{source_id} not found")
          end
        end
      end)
    end

    defaults([:read])
  end

  identities do
    # 同一 workspace 下 (name, version) 唯一；不同 workspace 可重名
    identity(:unique_name_version_per_workspace, [:workspace_id, :name, :version])
  end

  postgres do
    table("workflow_definitions")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：仅 workspace 成员或平台管理员可读，杜绝跨租户泄露
    # （对比：原 actor_present() 配合 global?(true) 会让任意登录用户读到任意租户定义）
    policy action_type(:read) do
      authorize_if(relates_to_actor_via([:workspace, :memberships, :user]))
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end

    # 写操作：Owner/Admin（多角色并集）或平台管理员
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(actor_attribute_equals(:is_platform_admin, true))
    end
  end

  graphql do
    type(:workflow_definition)
  end
end
