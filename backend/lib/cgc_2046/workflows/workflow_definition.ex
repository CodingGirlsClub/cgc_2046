defmodule Cgc2046.Workflows.WorkflowDefinition do
  @moduledoc """
  Workflow 蓝图资源（Slice C #34）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：WorkflowDefinition 是声明式 DAG 蓝图，
  带版本管理；改定义不影响已开始 run（D-A2，已开始 run 持当时 published 版本）。

  ## ADR-0003 纪律

  - **蓝图是数据不是代码**：node_def 只存执行拓扑（步骤顺序/依赖），Step 字段（type/action/
    sub_definition_id）独立存于 Step 资源。运行时由引擎读取驱动执行，改定义不改代码。
  - **核心是协议不是框架**：本资源只描述「做什么步骤、什么顺序、什么类型」，不内建审批/MCP/审计
    逻辑——这些通过 Step 的 action（指向经 StepHandlerRegistry 注册的模块）外置。

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

  require Ash.Query

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  # WorkflowDefinition.type 全 5 枚举（R3 裁决 2026-08-16：删 platform_ops——零驱动的死枚举；
  # enrollment/sponsorship 为实体自序贯预留，learning/curriculum/speaker_invitation 有 instantiator）
  @type_values [
    :learning,
    :enrollment,
    :sponsorship,
    :speaker_invitation,
    :curriculum
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
        "workflow 类型：learning 学习 / enrollment 报名 / " <>
          "sponsorship 赞助 / speaker_invitation 邀请讲者 / curriculum 教研"
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

    # F7 方案 A：审批超时。实际语义：nil = 永不超时；非 nil = 人工步骤审批超时秒数
    # （不设默认值——创建期不写即 nil，永不超时）。deadline 派生唯一真源 =
    # Cgc2046.ApprovalDeadline（updated_at + approval_timeout）。
    attribute(:approval_timeout, :integer,
      public?: true,
      writable?: true,
      description: "人工步骤审批超时秒数；nil = 永不超时（不设默认值）"
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
                # #15：Step/StepRole 复制放 after_action（需新定义 id 已生成）
                |> Ash.Changeset.put_context(:new_version_source, {source, tenant})
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

      # #15：新定义落库后复制 source 的 Step/StepRole 行（manual 步骤授权配置不能丢）。
      # 同事务（Ash create 默认 transaction?: true），失败回滚新定义。
      # after_action 契约：result 是裸 record，返回值须 {:ok, result} / {:error, error}。
      change(
        after_action(fn changeset, result, _context ->
          case changeset.context[:new_version_source] do
            {source, tenant} when is_struct(source) and is_binary(tenant) ->
              copy_steps(result, source, tenant)

            _ ->
              :ok
          end

          {:ok, result}
        end)
      )
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

    # #18：workspace_id 索引声明进 DSL（原先只在迁移手加，Ash codegen 不可见，
    # snapshot squash 会丢）；multitenancy 按 workspace_id 过滤，必查索引。
    custom_indexes do
      index([:workspace_id])
    end
  end

  policies do
    # 读取（H3）：仅 workspace 成员或平台管理员可读，杜绝跨租户泄露
    # （对比：原 actor_present() 配合 global?(true) 会让任意登录用户读到任意租户定义）
    policy action_type(:read) do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # 写操作：Owner/Admin（多角色并集）
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  graphql do
    type(:workflow_definition)
  end

  # --- 私有实现 --------------------------------------------------------------

  # #15：new_version 复制 source 的 Step 行 + StepRole 关联（同事务）。
  # Step 字段按可写属性全量复制（definition_id 换新）；StepRole 按 step_id → 新 step_id
  # 映射重建（role_id 不变——Role 是 workspace 级资源，非 definition 级）。
  defp copy_steps(new_def, source, tenant) do
    with {:ok, source_steps} <-
           Ash.Query.filter(Cgc2046.Workflows.Step, definition_id == ^source.id)
           |> Ash.read(tenant: tenant, authorize?: false) do
      Enum.each(source_steps, fn source_step ->
        case create_copied_step(source_step, new_def.id, tenant) do
          {:ok, new_step} ->
            copy_step_roles(source_step.id, new_step.id, tenant)

          {:error, reason} ->
            raise "new_version failed to copy step #{source_step.step_key}: #{inspect(reason)}"
        end
      end)
    end

    :ok
  end

  defp create_copied_step(source_step, new_definition_id, tenant) do
    attrs = %{
      definition_id: new_definition_id,
      step_key: source_step.step_key,
      title: source_step.title,
      type: source_step.type,
      action: source_step.action,
      sub_definition_id: source_step.sub_definition_id,
      input_schema: source_step.input_schema
    }

    Cgc2046.Workflows.Step
    |> Ash.Changeset.for_create(:create, attrs, tenant: tenant, authorize?: false)
    |> Ash.create(tenant: tenant, authorize?: false)
  end

  defp copy_step_roles(source_step_id, new_step_id, tenant) do
    case Ash.Query.filter(Cgc2046.Workflows.StepRole, step_id == ^source_step_id)
         |> Ash.read(tenant: tenant, authorize?: false) do
      {:ok, step_roles} ->
        Enum.each(step_roles, fn step_role ->
          Cgc2046.Workflows.StepRole
          |> Ash.Changeset.for_create(
            :create,
            %{step_id: new_step_id, role_id: step_role.role_id},
            tenant: tenant,
            authorize?: false
          )
          |> Ash.create(tenant: tenant, authorize?: false)
        end)

      {:error, _} ->
        :ok
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:workflows)
    label_field(:name)
    table_columns([:id, :workspace_id, :name, :type, :version, :status, :inserted_at])
  end
end
