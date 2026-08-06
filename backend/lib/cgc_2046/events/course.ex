defmodule Cgc2046.Events.Course do
  @moduledoc """
  课程资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Course 与 Event 字段同构
  （仅无场地/时间字段），教研字段一致。本阶段只建教研 workflow 实例化所需字段；
  报名/赞助字段后续 slice 再加。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `course.launched` 信号（经 JidoAdapter 信号总线），
  `Cgc2046.Workflows.ResearchInstantiator` 订阅该信号创建教研 WorkflowRun。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Workflows.JidoAdapter

  @status_values [:draft, :open, :closed, :cancelled]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:title, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "课程标题"
    )

    attribute(:research_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否启用教研 workflow"
    )

    attribute(:research_requirements, :map,
      default: %{},
      public?: true,
      writable?: true,
      description: "教研材料需求（audience/duration/sections 等），作为 run input 注入"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @status_values],
      description: "课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消"
    )

    attribute(:workflow_run_id, :uuid,
      public?: true,
      writable?: true,
      description: "教研 workflow 产物引用（领域模型 §5.2 ER）"
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
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :workflow_run_id,
      destination_attribute: :id,
      allow_nil?: true
    )
  end

  actions do
    default_accept([:title, :research_enabled, :research_requirements])

    create :create do
      description("创建课程（默认 status=draft）")
      accept([:title, :research_enabled, :research_requirements])

      change(set_attribute(:status, :draft))

      # workspace_id 由 tenant 强制（同 WorkflowRun.create 模式），不接受调用方传入
      change(fn changeset, _context ->
        case changeset.tenant do
          nil -> Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
          tenant -> Ash.Changeset.force_change_attribute(changeset, :workspace_id, tenant)
        end
      end)
    end

    # draft → open：发布课程，发 course.launched 信号（教研实例化入口）。
    # 信号经 JidoAdapter 总线异步投递，ResearchInstantiator 订阅后创建教研 run。
    update :launch do
      description("发布课程：draft → open，发 course.launched 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :status) do
          :draft ->
            changeset = Ash.Changeset.force_change_attribute(changeset, :status, :open)

            tenant = changeset.tenant
            id = Ash.Changeset.get_data(changeset, :id)
            title = Ash.Changeset.get_data(changeset, :title)
            requirements = Ash.Changeset.get_data(changeset, :research_requirements) || %{}

            case JidoAdapter.publish(
                   "course.launched",
                   %{
                     "course_id" => id,
                     "title" => title,
                     "research_requirements" => requirements
                   },
                   tenant
                 ) do
              :ok ->
                changeset

              {:error, reason} ->
                Ash.Changeset.add_error(changeset, "signal publish failed: #{inspect(reason)}")
            end

          status ->
            Ash.Changeset.add_error(changeset, "cannot launch from status=#{status}")
        end
      end)
    end

    defaults([:read])

    # #40 展示页：按 id 取课程详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end
  end

  postgres do
    table("courses")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取（H3）：经 workspace → memberships 路径，仅成员或平台管理员
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
    type(:course)

    queries do
      list(:list_courses, :read, description: "工作台的课程列表（#40 展示页）")
      read_one(:get_course, :get_by_id, description: "按 id 获取课程（#40）")
    end
  end
end
