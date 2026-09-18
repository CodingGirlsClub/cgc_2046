defmodule Cgc2046.Recruitment.RecruitmentCohort do
  @moduledoc """
  招募批次（R8；KTD2 租户与 policy 边界）。

  不变量「同一 workspace 至多一个 open」由 **DB 部分唯一索引**承载
  （`recruitment_cohorts_unique_open_per_workspace_index`，`WHERE status = 'open'`）——
  并发下也成立，且不随调用面漂移；identity 只作索引名的 DSL 声明面，
  **eager check 必须关闭**：Ash 的 eager check 只按 identity keys 过滤、不带
  `where`，开启会把同台既有 draft/closed 批次误判成冲突。

  读面：匿名可读 open（公开申请页只依赖 open 批次，R10）；draft/closed 只有
  Owner/Admin ∪ platform_admin 可见。写面：Owner/Admin ∪ platform_admin。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Recruitment

  @statuses [:draft, :open, :closed]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "所属工作台（租户）ID（KTD2：workspace_id + global?(true)）"
    )

    attribute(:name, :string,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "批次名称（如「第 1 批」）"
    )

    attribute(:apply_deadline_at, :utc_datetime,
      allow_nil?: false,
      public?: true,
      writable?: true,
      description: "申请截止时间（UTC 存储，展示走既有格式化路径）"
    )

    attribute(:starts_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "执行周期开始（可空）"
    )

    attribute(:ends_at, :utc_datetime,
      public?: true,
      writable?: true,
      description: "执行周期结束（可空）"
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses],
      description: "状态：draft | open | closed（仅 :open / :close 动作可迁移）"
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
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
  end

  identities do
    # 至多一个 open（AE9）：索引由手写 migration 建为部分唯一索引，
    # 索引名 = identity 推导名（IndexCatalog 公式），此处只声明语义。
    # eager_check?(false) 是刻意的——见 moduledoc。
    identity :unique_open_per_workspace, [:workspace_id] do
      where(expr(status == :open))
      eager_check?(false)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :apply_deadline_at, :starts_at, :ends_at])
    end

    update :update do
      require_atomic?(false)
      accept([:name, :apply_deadline_at, :starts_at, :ends_at])
    end

    # 开放批次：撞「已有 open」→ 条件唯一索引冲突 → 稳定业务 code（AE9）
    update :open do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :open))
      error_handler({__MODULE__, :handle_write_error, []})
    end

    update :close do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :closed))
    end
  end

  postgres do
    table("recruitment_cohorts")
    repo(Cgc2046.Repo)

    # 部分唯一索引的 SQL 表示（identity `where` 的落库形状）：索引由手写
    # migration 建，此处是 snapshot/生成器的同源声明（缺它会拒绝生成 snapshot）
    identity_wheres_to_sql(unique_open_per_workspace: "status = 'open'")
  end

  policies do
    policy action_type(:read) do
      # 匿名（公开申请页）与任何已登录用户：只见 open 批次
      authorize_if(expr(status == :open))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # 条件唯一索引冲突（第二个 open）→ 稳定业务错误。按约束名分派（同表日后加
  # identity 不误归因）；非 unique 冲突原样上抛（fail-closed），范式同
  # EventModerator.handle_write_error/2（#611）。
  @doc false
  def handle_write_error(_changeset, error) do
    if Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
         Cgc2046.Errors.ConstraintConflict.constraint_named?(
           error,
           "recruitment_cohorts_unique_open_per_workspace_index"
         ) do
      Cgc2046.Errors.BusinessError.exception(
        message: "another cohort is already open in this workspace",
        code: "recruitment_cohort_open_conflict",
        fields: [:status]
      )
    else
      error
    end
  end
end
