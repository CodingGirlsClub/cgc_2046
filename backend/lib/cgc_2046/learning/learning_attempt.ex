defmodule Cgc2046.Learning.Attempt do
  @moduledoc """
  学习评价尝试资源（role-agent-journeys-v2 S8，R42/R44；ADR-0011 L1）：
  **不可变**的正式评价账本行。

  一行 = 一次正式评价（formal evaluation），取代 LearningRecord
  （latest-only upsert；已随本切片删除，无兼容层）：

  - 锚定三元组：`learning_run_id`（哪个学习 run）+ `course_revision_id`
    （哪份不可变课程内容快照）+ `objective_id`（快照内稳定 id 的掌握单元）；
  - `evidence`（学员提交的证据/作答摘要）+ `rubric_results`（逐条
    `%{criterion_id, met, note?}`）+ `passed` + `rationale`（判定理由，必填）
    + `confidence`（0..1）+ `agent_meta`（客户端/模型元数据）；
  - **不可变：只定义 `:create` 与读 action**——无 update/destroy；失败评价
    永不删除，重试写新行（R44：all attempts kept，无限重试，无 tutor 逐条复核）。

  掌握状态（mastery）**不落库**：由 `Cgc2046.Learning.Mastery` 从 attempts
  纯函数派生（unassessed/developing/mastered/needs_review，R43）；rubric 未
  全达标或 confidence < 0.8 不构成 qualifying 掌握（判据单源在 Mastery）。

  ## 多租户与授权

  multitenancy attribute :workspace_id（Learning 家族同款，`global?(true)`）。
  读面（R48）：学员本人（经 learning_run `input_snapshot["user_id"]` 锚定）∪
  本工作台 tutor/owner/admin（必要证据可读）。**平台管理员刻意不放行**——
  证据内容不进平台治理读面（元数据审计面归 S10 audit，不在本资源）。
  写面：仅学员本人（工具层授权后经 `submit_learning_attempt` 落库；
  资源层 SimpleCheck 兜底）。

  不开 GraphQL 面（消费全走 MCP 工具 + Runs 投影；LearningRecord 同款先例）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Learning

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID"
    )

    attribute(:learning_run_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "所属学习 run（workflow_runs.id；R42 锚定）"
    )

    attribute(:course_revision_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "评价针对的课程版本快照（curriculum_course_revisions.id；run 创建时绑定的同一版本）"
    )

    attribute(:objective_id, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "掌握单元 id（版本快照内稳定 id，宽存字符串）"
    )

    attribute(:evidence, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "学员提交的证据/作答摘要"
    )

    attribute(:rubric_results, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true,
      description: "逐条评分结果 [%{criterion_id, met, note?}]（须精确覆盖 objective rubric 全部 criterion id）"
    )

    attribute(:passed, :boolean,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "agent 判定的通过与否（不构成掌握——掌握由 Mastery 投影派生）"
    )

    attribute(:rationale, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "判定理由摘要（agent 推理；恒必填）"
    )

    attribute(:confidence, :float,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [min: 0.0, max: 1.0],
      description: "判定置信度 0..1；< 0.8 不构成 qualifying 掌握（R43）"
    )

    attribute(:agent_meta, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: true,
      description: "agent 元数据（客户端名/模型等）"
    )

    # 不可变账本：只有 created_at，无 updated_at
    create_timestamp(:created_at, public?: true)
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

    belongs_to(:learning_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :learning_run_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:course_revision, Cgc2046.Curriculum.CourseRevision,
      source_attribute: :course_revision_id,
      destination_attribute: :id,
      allow_nil?: false
    )
  end

  actions do
    default_accept([
      :learning_run_id,
      :course_revision_id,
      :objective_id,
      :evidence,
      :rubric_results,
      :passed,
      :rationale,
      :confidence,
      :agent_meta
    ])

    # 唯一写入口 = submit_learning_attempt 工具（工具层授权 + 校验链已过，
    # authorize?: false 系统效应，同 CourseRevision 发布步纪律）。
    # 不可变纪律（R42/R44）：不定义任何 update/destroy action。
    create :create do
      description("创建学习评价尝试（不可变账本行；无 update/destroy）")
    end

    defaults([:read])
  end

  postgres do
    table("learning_attempts")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:workspace_id])
      index([:learning_run_id])
      index([:course_revision_id])
      index([:learning_run_id, :objective_id, :created_at])
    end
  end

  policies do
    # 读（R48）：学员本人（run 锚定）∪ 本工作台 tutor/owner/admin。
    # 平台管理员刻意不在此列——证据读面不进平台治理（元数据审计归 S10）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.ActorReadsLearningAttempt)
    end

    # 写：仅学员本人（run input_snapshot 的 user_id 锚定；SimpleCheck 读 run 判定）
    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.ActorIsAttemptLearner)
    end
  end

  admin do
    resource_group(:learning)

    table_columns([
      :id,
      :workspace_id,
      :learning_run_id,
      :course_revision_id,
      :objective_id,
      :passed,
      :confidence,
      :created_at
    ])
  end
end
