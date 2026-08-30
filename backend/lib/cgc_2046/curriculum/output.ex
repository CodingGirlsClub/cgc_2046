defmodule Cgc2046.Curriculum.Output do
  @moduledoc """
  教研产出资源(切片 H U1, #180;ADR-0009 PR③ 自 Workflows.ResearchOutput 迁入改名):
  课程内容的唯一持久层。

  - `(key, kind)` 唯一,key = `course_<id>`(`course_key/1` 单源约定,
    CurriculumProgressWorker / save_course_content 工具共用);`(key, kind)`
    全局唯一(course id 全局唯一,重复即 bug)。
  - v1 `kind = :issues`:课程内容本体(course content JSONB,形状校验见
    `Cgc2046.Curriculum.Content`);`:materials` / `:archive` 设计保留、
    实现后置(设计 §4.1)。
  - **活文档**:`upsert_content` 按 `(key, kind)` 更新 data 与审计列,不产生
    多行(KTD4:id 稳定纪律 + 学习记录引用 id,内容编辑不破坏进行中学员);
    run 终态后仍可更新(设计 §4.1 Q8)。
  - **草稿版本(S4,R9/R10)**:`version` 乐观并发——首存传 `base_version: 0`
    落 version 1;其后传当前 version,成功 +1。陈旧 base_version 由
    `upsert_condition` 原子拦截(DB 单语句 check-and-write,零行即冲突),
    并发首存撞 `(key,kind)` 唯一亦归并为同一 version_conflict 语义。
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
    domain: Cgc2046.Curriculum

  require Ash.Query

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
      description: "course content JSONB(goals + issues,形状见 Cgc2046.Curriculum.Content)"
    )

    attribute(:version, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      writable?: false,
      description: "草稿版本(S4 乐观并发):首存 1,每次成功写入 +1;调用方不直写"
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
    # upsert_fields 限定更新面——key/kind 是身份不改;version 不在更新面,
    # 由 atomic_update 在 ON CONFLICT 更新相 +1(INSERT 相取属性默认 1)。
    #
    # 乐观并发契约(S4 R9/R10,§B#8):
    # - base_version 必传:首存 0,其后为 get_course_content 返回的当前 version;
    # - upsert_condition 把 version == base_version 下推为冲突更新相的 WHERE
    #   子句——check-and-write 单语句原子,不命中即 StaleRecord(并发首存撞
    #   (key,kind) 唯一同归此路:他方已写,version ≥ 1 ≠ 0);
    # - base_version > 0 而行不存在 = 首存传错基准:行只增不删(无 destroy
    #   action),存在性前置检查无竞态,版本匹配仍由 upsert_condition 原子兜底。
    create :upsert_content do
      description("保存/更新课程内容(活文档,(key,kind) upsert;唯一写入口为 MCP 工具)")

      accept([:key, :kind, :data, :submitted_by, :workflow_run_id])

      argument(:base_version, :integer,
        allow_nil?: true,
        description: "乐观并发基准版本:首存传 0;其后传 get_course_content 返回的当前 version"
      )

      upsert?(true)
      upsert_identity(:unique_key_kind)
      upsert_fields([:data, :submitted_by, :workflow_run_id])
      upsert_condition(expr(version == ^arg(:base_version)))

      change(fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :base_version) do
          nil ->
            Ash.Changeset.add_error(
              changeset,
              "base_version is required (read the current draft via get_course_content first)"
            )

          0 ->
            changeset

          base when is_integer(base) ->
            if draft_exists?(changeset) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                Cgc2046.Errors.BusinessError.exception(
                  message: version_conflict_message(0),
                  code: "version_conflict",
                  fields: [:base_version]
                )
              )
            end
        end
      end)

      change(atomic_update(:version, expr(version + 1)))
    end

    defaults([:read])
  end

  validations do
    validate(Cgc2046.Curriculum.ContentValidation)
  end

  identities do
    # all_tenants?:(key,kind) 全局唯一(course id 全局唯一);否则 :attribute 多租户
    # 会把 workspace_id 并入冲突目标,与全局唯一索引不匹配(42P10)
    identity(:unique_key_kind, [:key, :kind], all_tenants?: true)
  end

  postgres do
    table("curriculum_outputs")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:workspace_id])
    end
  end

  policies do
    # 读取:workspace 成员或平台管理员(学员侧豁免在工具层,U3)
    policy action_type(:read) do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 写入:成员门槛在资源层;tutor ∪ owner/admin 细粒度判定在工具层(U3,
    # update_facts_for_mcp bypass 同款纪律)
    policy action_type(:create) do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪
    resource_group(:curriculum)
    label_field(:key)
    table_columns([:id, :workspace_id, :key, :kind, :submitted_by, :inserted_at])
  end

  # --- 纯函数单源 --------------------------------------------------------------

  @doc "课程内容 key 约定(`course_<id>`);CurriculumProgressWorker 与 save_course_content 共用。"
  @spec course_key(String.t()) :: String.t()
  def course_key(course_id) when is_binary(course_id), do: "course_#{course_id}"

  @doc """
  version_conflict 错误文案单源(存在性前置检查与 save_course_content 工具的
  StaleRecord 映射共用)。`current_version` 为冲突时读到的当前版本,无草稿为 0。
  """
  @spec version_conflict_message(non_neg_integer()) :: String.t()
  def version_conflict_message(current_version) do
    "version_conflict: draft is at version #{current_version}; " <>
      "re-read with get_course_content and retry"
  end

  # base_version > 0 的存在性前置(见 upsert_content 注释);authorize?: false——
  # 写门禁在资源 create policy / 工具层,本检查只是契约守门
  defp draft_exists?(changeset) do
    key = Ash.Changeset.get_attribute(changeset, :key)
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    __MODULE__
    |> Ash.Query.filter(key == ^key and kind == ^kind)
    |> Ash.exists?(authorize?: false, tenant: changeset.tenant)
  end
end
