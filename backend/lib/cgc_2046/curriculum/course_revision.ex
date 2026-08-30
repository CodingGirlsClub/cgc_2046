defmodule Cgc2046.Curriculum.CourseRevision do
  @moduledoc """
  课程版本（role-agent-journeys-v2 S6，R29/R38）：发布即冻结的**不可变**
  课程内容快照。

  - 教研流程发布步（`Cgc2046.Curriculum.Prep.publish/4`）冻结当前草稿
    （`Curriculum.Output` 活文档）为本资源一行；`content` 是发布时点的完整
    schema v2 内容（goals + issues + objectives）。
  - **`(course_id, number)` 唯一且 per-course 单调递增**——发布步在发布事务内
    取 `max(number)+1`（唯一索引兜底，撞号重试一次）。
  - **不可变（R29）**：只定义 `:create` 与读 action——无 update/destroy；旧
    版本永远不被改写。后续编辑从当前 published revision 派生新草稿，再发布
    生成下一个版本。
  - `prep_run_id` 溯源到产出本版本的教研 run；`published_by_id` /
    `published_at` 为发布审计列。
  - `Cgc2046.Courses.Course.current_revision_id` 指向课程当前 published 版本
    （发布端口 `bind_revision_for_publish/3` 写入）；公开课程地图（courseMap）
    读该版本而非草稿，从未发布过的存量课程回退草稿读面
    （`Course.published_content/1`）。

  ## 多租户与授权

  multitenancy attribute :workspace_id（Curriculum 家族同款）；资源层 policy 做
  成员门槛（读/写）+ 平台管理员跨租户读。学员侧「仅最新 published 版本」的
  细粒度判定在 `get_course_revision` 工具层（get_course_content 同款 deferred
  纪律）。**不开 GraphQL 面**（消费全走 MCP 工具 + 域读入口，先例 =
  CapacityLedger / WebhookEvent：无 AshGraphql 扩展即无泄露面）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Curriculum

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:course_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "所属课程 ID；与 number 联合唯一"
    )

    attribute(:number, :integer,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "版本号：per-course 单调递增，发布步取 max(number)+1"
    )

    attribute(:content, :map,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "发布时点的完整内容快照（schema v2：goals + issues + objectives）"
    )

    attribute(:prep_run_id, :uuid,
      public?: true,
      writable?: true,
      description: "产出本版本的教研 run（溯源列）"
    )

    attribute(:published_by_id, :uuid,
      public?: true,
      writable?: true,
      description: "发布人（教研流程发布步的认证用户）ID"
    )

    attribute(:published_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "发布时间（发布步写入）"
    )

    create_timestamp(:inserted_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    # 供成员授权路径（path: [:workspace]，Output 同款）与租户归属读取
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:course, Cgc2046.Courses.Course,
      source_attribute: :course_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:prep_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :prep_run_id,
      destination_attribute: :id,
      allow_nil?: true
    )
  end

  actions do
    default_accept([:course_id, :number, :content, :prep_run_id, :published_by_id, :published_at])

    # 唯一写入口 = 教研流程发布步（Curriculum.Prep.publish，authorize?: false
    # 系统效应）。不可变纪律（R29）：不定义任何 update/destroy action。
    create :create do
      description("创建课程版本（发布即冻结；immutable——无 update/destroy）")
    end

    defaults([:read])
  end

  identities do
    # all_tenants?：course_id 全局唯一，(course_id, number) 即全局唯一；否则
    # :attribute 多租户会把 workspace_id 并入冲突目标，与全局唯一索引不匹配
    # （42P10，Output.unique_key_kind 同款判据）
    identity(:unique_course_number, [:course_id, :number], all_tenants?: true)
  end

  postgres do
    table("curriculum_course_revisions")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:workspace_id])
    end
  end

  policies do
    # 读取：workspace 成员或平台管理员（学员「仅最新版本」豁免在工具层，S6）
    policy action_type(:read) do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 写入：成员门槛在资源层；发布步是教研流程系统效应（authorize?: false），
    # 迁移授权已在 MCP 工具层完成（Prep.publish 同款纪律）
    policy action_type(:create) do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  admin do
    resource_group(:curriculum)

    table_columns([:id, :workspace_id, :course_id, :number, :published_by_id, :published_at])
  end
end
