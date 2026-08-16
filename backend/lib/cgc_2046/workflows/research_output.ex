defmodule Cgc2046.Workflows.ResearchOutput do
  @moduledoc """
  教研产出资源(切片 H U1, #180):课程内容的唯一持久层。

  - `(key, kind)` 唯一,key = `course_<id>`(`course_key/1` 单源约定,
    ResearchProgressWorker / save_course_content 工具共用);`(key, kind)`
    全局唯一(course id 全局唯一,重复即 bug)。
  - v1 `kind = :issues`:课程内容本体(course content JSONB,形状校验见
    `Cgc2046.Workflows.CourseContent`);`:materials` / `:archive` 设计保留、
    实现后置(设计 §4.1)。
  - **活文档**:`upsert_content` 按 `(key, kind)` 更新 data 与审计列,不产生
    版本流(KTD4:id 稳定纪律 + 学习记录引用 id,内容编辑不破坏进行中学员);
    run 终态后仍可更新(设计 §4.1 Q8)。
  - 写入口 = MCP `save_course_content`(KTD1);`save_step_output` 只写 run
    facts,不落本表。

  ## 多租户与授权

  multitenancy attribute :workspace_id(workflow 家族);资源层 policy 做成员
  门槛(读/写),学员侧豁免与 tutor ∪ owner/admin 细粒度判定在工具层
  (U3,`save_step_output` 的三层授权同款纪律)。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  @kind_values [:issues]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台(租户)ID"
    )

    attribute(:key, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "产出键(course_<id>);与 kind 联合唯一,活文档按 key 更新"
    )

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      writable?: true,
      constraints: [one_of: @kind_values],
      description: "产出类型:v1 仅 issues(issue 卡集);materials/archive 后置"
    )

    attribute(:data, :map,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "course content JSONB(goals + issues,形状见 CourseContent)"
    )

    attribute(:submitted_by, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "提交人(Tutor/教研 agent 会话的认证用户)ID"
    )

    attribute(:workflow_run_id, :uuid,
      public?: true,
      writable?: true,
      description: "关联教研 run(审计列;facts 镜像目标)"
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
    # 供成员授权路径(path: [:workspace])与租户归属读取
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
    default_accept([:key, :kind, :data, :submitted_by, :workflow_run_id])

    # 活文档写入:(key, kind) 命中则更新 data/审计列,否则插入。
    # upsert_fields 限定更新面——key/kind 是身份不改。
    create :upsert_content do
      description("保存/更新课程内容(活文档,(key,kind) upsert;唯一写入口为 MCP 工具)")

      accept([:key, :kind, :data, :submitted_by, :workflow_run_id])

      upsert?(true)
      upsert_identity(:unique_key_kind)
      upsert_fields([:data, :submitted_by, :workflow_run_id])
    end

    defaults([:read])
  end

  validations do
    validate(Cgc2046.Workflows.CourseContentValidation)
  end

  identities do
    # all_tenants?:(key,kind) 全局唯一(course id 全局唯一);否则 :attribute 多租户
    # 会把 workspace_id 并入冲突目标,与全局唯一索引不匹配(42P10)
    identity(:unique_key_kind, [:key, :kind], all_tenants?: true)
  end

  postgres do
    table("research_outputs")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:workspace_id])
    end
  end

  policies do
    # 读取:workspace 成员或平台管理员(学员侧豁免在工具层,U3)
    policy action_type(:read) do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    # 写入:成员门槛在资源层;tutor ∪ owner/admin 细粒度判定在工具层(U3,
    # update_facts_for_mcp bypass 同款纪律)
    policy action_type(:create) do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪
    resource_group(:workflows)
    label_field(:key)
    table_columns([:id, :workspace_id, :key, :kind, :submitted_by, :inserted_at])
  end

  # --- 纯函数单源 --------------------------------------------------------------

  @doc "课程内容 key 约定(`course_<id>`);ResearchProgressWorker 与 save_course_content 共用。"
  @spec course_key(String.t()) :: String.t()
  def course_key(course_id) when is_binary(course_id), do: "course_#{course_id}"
end
