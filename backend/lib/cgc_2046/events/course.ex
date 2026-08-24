defmodule Cgc2046.Events.Course do
  @moduledoc """
  课程资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Course 与 Event 字段同构
  （线上课程，无 venue 场地字段；starts_at/ends_at 语义为开课/结课），教研字段一致。
  Phase 2 加入报名策略、容量与报名截止时间；
  `confirmed_count` 由 Enrollment 的数据库条件 UPDATE 原子维护。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `course.launched` 信号（SignalEmitter 事务内
  outbox 入队，SignalPublishWorker 经 JidoAdapter 总线异步投递），
  `Cgc2046.Workflows.ResearchInstantiator` 订阅该信号创建教研 WorkflowRun。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Api

  alias Cgc2046.Repo
  require Ash.Query
  @status_values [:draft, :open, :closed, :cancelled]
  @enrollment_policy_values [:open, :request, :invite_only]
  @visibility_values [:public, :workspace]
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

    attribute(:slug, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开 URL 段（/courses/[slug]，全局唯一）"
    )

    attribute(:description, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开展示文案（可空；null 由展示层按空串呈现）"
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

    attribute(:enrollment_policy, :atom,
      allow_nil?: false,
      default: :open,
      public?: true,
      writable?: true,
      constraints: [one_of: @enrollment_policy_values],
      description: "报名策略：open / request / invite_only"
    )

    attribute(:visibility, :atom,
      allow_nil?: false,
      default: :public,
      public?: true,
      writable?: true,
      constraints: [one_of: @visibility_values],
      description: "可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9）"
    )

    attribute(:capacity, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "报名名额上限；nil 表示不限"
    )

    attribute(:confirmed_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      writable?: false,
      constraints: [min: 0],
      description: "已确认名额数（仅由 Enrollment 原子维护）"
    )

    attribute(:registration_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "报名截止时间；nil 表示不设截止"
    )

    attribute(:starts_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "开课时间；nil 表示未定（R1，Course 语义为开课/结课）"
    )

    attribute(:ends_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1）"
    )

    attribute(:pricing_enabled, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "是否收费（默认免费；true 时报名须选档并完成支付，R4）"
    )

    attribute(:price_tiers, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true,
      description: "价格档位配置（PriceTier 形状，见 price_tier.ex）"
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  validations do
    validate({Cgc2046.Events.PriceTiersValidation, []})
    validate({Cgc2046.Events.ScheduleValidation, []})
  end

  calculations do
    # R2 报名面：只暴露未过 available_until 的档位（过滤逻辑在 PriceTier）。
    # load: GraphQL 单独请求本计算字段时 ash_graphql 不自动 select 依赖列,
    # price_tiers 落 NotLoaded → available_tiers 误判空(load 依赖声明后由 Ash 补载)。
    calculate(:available_price_tiers, {:array, :map},
      public?: true,
      load: [:price_tiers],
      calculation: fn records, _opts ->
        Enum.map(records, &Cgc2046.Events.PriceTier.available_tiers(&1.price_tiers))
      end
    )

    # R6/KTD1 公开派生标签：full > closed > starting_soon > enrolling（逻辑在 EnrollmentBadge）。
    # load 依赖声明同上；capacity/confirmed_count 本体仍留 field_policy denylist。
    calculate(:enrollment_badge, :atom,
      public?: true,
      constraints: [one_of: [:enrolling, :starting_soon, :closed, :full]],
      load: [:capacity, :confirmed_count, :starts_at, :registration_deadline],
      calculation: fn records, _opts ->
        now = DateTime.utc_now()
        Enum.map(records, &Cgc2046.Events.EnrollmentBadge.badge(&1, now))
      end
    )
  end

  # 地图行(goal-only,R10):key 派生(KTD6)= slug 短码 + 卡集内 1 起序号。
  # 唯一消费方 = graphql_schema resolve_course_map(G3:calculate 包装已删,
  # 无 GraphQL/Ash 面需要,留纯函数直调)
  @doc false
  def issue_map_rows(%__MODULE__{} = course) do
    content = course_content(course)

    content
    |> Cgc2046.Workflows.CourseContent.issues()
    |> Enum.with_index(1)
    |> Enum.map(fn {issue, idx} ->
      %{
        key: Cgc2046.Workflows.LearningProgress.issue_key(course.slug, idx),
        id: issue["id"],
        title: issue["title"],
        kind: issue["kind"],
        goal: issue["story"]["goal"]
      }
    end)
  end

  # U7:课程内容读取(公开地图与学员详情共用源);authorize?: false——门禁在
  # 调用面(course 读 policy / 学习详情工具层授权),内容本体无独立敏感面
  # (goal-only 投影由调用方负责;本函数返回全量 content,不外泄 checklist 的
  # 责任在投影层)。
  def course_content(%__MODULE__{id: id, workspace_id: workspace_id})
      when is_binary(id) and is_binary(workspace_id) do
    Cgc2046.Workflows.ResearchOutput
    |> Ash.Query.filter(
      key == ^Cgc2046.Workflows.ResearchOutput.course_key(id) and kind == :issues
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, output} -> output && output.data
      _ -> nil
    end
  end

  def course_content(_course), do: nil

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

    # U8(#180/R12):public? 暴露关系字段供管理页教研状态露出(workflowRunId
    # 只有引用 id,run 状态需关系行;读门禁沿用 course read policy + run 侧
    # member policy)
    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :workflow_run_id,
      destination_attribute: :id,
      allow_nil?: true,
      public?: true
    )
  end

  actions do
    default_accept([
      :title,
      :research_requirements,
      :enrollment_policy,
      :capacity,
      :registration_deadline,
      :starts_at,
      :ends_at,
      :visibility,
      :slug,
      :description,
      :pricing_enabled,
      :price_tiers
    ])

    create :create do
      description("创建课程（默认 status=draft）")

      accept([
        :title,
        :research_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :starts_at,
        :ends_at,
        :visibility,
        :slug,
        :description,
        :pricing_enabled,
        :price_tiers
      ])

      # GraphQL 入口不注入 tenant（#104 同款），workspace_id 由入参提供；
      # 内部调用方（fixtures/测试）直接传 tenant 亦可。policy 经
      # MembershipContext 的 argument 回退解析工作台（invitation.ex 同款先例）。
      argument(:workspace_id, :uuid,
        allow_nil?: true,
        description: "目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略）"
      )

      change(set_attribute(:status, :draft))

      # slug 未提供时兜底生成（公开 URL 段；唯一索引防碰撞）
      change(fn changeset, _context ->
        changeset =
          case Ash.Changeset.get_attribute(changeset, :slug) do
            value when is_binary(value) and value != "" ->
              changeset

            _ ->
              suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
              Ash.Changeset.force_change_attribute(changeset, :slug, "c-" <> suffix)
          end

        changeset
      end)

      # slug 单段 URL 约束（公开路由 /courses/[slug]；非法字符拒绝）
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :slug) do
          value when is_binary(value) and value != "" ->
            if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, value) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                "slug must be a single lowercase URL segment ([a-z0-9-])"
              )
            end

          _ ->
            changeset
        end
      end)

      # workspace_id 由 argument 或 tenant 强制，不接受属性直传
      change(fn changeset, _context ->
        workspace_id = Ash.Changeset.get_argument(changeset, :workspace_id) || changeset.tenant

        if workspace_id do
          changeset
          |> Ash.Changeset.set_tenant(workspace_id)
          |> Ash.Changeset.force_change_attribute(:workspace_id, workspace_id)
        else
          Ash.Changeset.add_error(changeset, "create requires a tenant (workspace_id)")
        end
      end)
    end

    # 编辑课程元数据（E-11 #127）：visibility 可随时双向切换（含 open 后，D9）。
    # status/workflow_run_id/confirmed_count 不在此 accept（状态走专用 action）。
    update :update do
      description("编辑课程元数据（Owner/Admin）")
      require_atomic?(false)

      accept([
        :title,
        :research_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :starts_at,
        :ends_at,
        :visibility,
        :slug,
        :description,
        :pricing_enabled,
        :price_tiers
      ])

      # 强制非原子执行（同 event.ex :update 注释——GraphQL bulk_update 原子
      # 路径下 policy 的 changeset.data 读取会 raise）。
      change(fn changeset, _context ->
        _ = Ash.Changeset.get_data(changeset, :status)
        changeset
      end)

      # slug 单段 URL 约束（create/update 同规则；非法拒绝）
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :slug) do
          value when is_binary(value) and value != "" ->
            if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, value) do
              changeset
            else
              Ash.Changeset.add_error(
                changeset,
                "slug must be a single lowercase URL segment ([a-z0-9-])"
              )
            end

          _ ->
            changeset
        end
      end)

      # R9 关闭收费批量免费确认（organizer-payment U3，KTD4）：true→false 时
      # 同事务对 payment_pending 报名逐条复用免缴三元组。
      change({Cgc2046.Changes.WaivePendingOnPricingDisable, kind: :course})
    end

    # draft → open：发布课程，发 course.launched 信号（教研实例化入口）。
    # 信号经 SignalEmitter 事务内 outbox 入队，SignalPublishWorker 提交后异步
    # 投递——订阅方读到的必是已提交 open 状态（#1 TOCTOU 由 outbox 结构性解决，
    # 不再有 for_update 阶段发布读未提交 draft 的窗口）。
    update :launch do
      description("发布课程：draft → open，发 course.launched 信号")
      require_atomic?(false)
      accept([])

      # DB 级 compare-and-set（复审：并发双 launch 会双信号）——before_action
      # 内条件 UPDATE 抢占 draft→open，后到者 num_rows=0 拒绝。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :draft ->
              case status_transition(cs, :open) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :open)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "launch failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot launch from status=#{status}")
          end
        end)
      end)

      change(
        {Cgc2046.Changes.SignalEmitter,
         type: "course.launched", payload: &__MODULE__.launched_payload/2}
      )

      # GO/NO-GO（D3 警告放行）：清单非 ready 记 warning 不阻塞发布，
      # 明细经 GraphQL readiness 查询暴露后台（event.launch 同款，Readiness 统一）。
      change(after_transaction(&Cgc2046.Events.Readiness.warn_unless_ready/3))
    end

    # open → closed：结束课程（手动，或 registration_deadline 到点由
    # EventLifecycleWorker 自动执行）。发 course.ended 信号——E-9 #124 级联：
    # 订阅方 = 教研 run 回收 / 报名窗锁定（赞助随 Event 语义，Course 无赞助）。
    # 终态不可逆（D4 v1 语义）：closed/cancelled 无恢复 action，恢复路径 =
    # 新建课程。DB 级 compare-and-set 防陈旧/并发双成功（cron 与手动竞态，
    # codex 评审 BLOCKING 4）。
    update :close do
      description("结束课程：open → closed，发 course.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :closed) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :closed)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "close failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot close from status=#{status}")
          end
        end)
      end)

      # course.ended 经 SignalEmitter 事务内 outbox 入队：job 与课程终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: "course.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    # open → cancelled：取消课程。同样发 course.ended（D4：closed/cancelled 即 ended）。
    update :cancel do
      description("取消课程：open → cancelled，发 course.ended 信号")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          case Ash.Changeset.get_data(cs, :status) do
            :open ->
              case status_transition(cs, :cancelled) do
                :ok ->
                  Ash.Changeset.force_change_attribute(cs, :status, :cancelled)

                {:error, :status_race} ->
                  Ash.Changeset.add_error(
                    cs,
                    "cancel failed: status changed concurrently, retry on fresh read"
                  )

                {:error, {:database, _} = reason} ->
                  Ash.Changeset.add_error(cs, reason)
              end

            status ->
              Ash.Changeset.add_error(cs, "cannot cancel from status=#{status}")
          end
        end)
      end)

      # course.ended 经 SignalEmitter 事务内 outbox 入队：job 与课程终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: "course.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    defaults([:read])

    # #14：教研 run 创建后回写产物引用（ResearchInstantiator 内部调用，authorize?: false）。
    # workflow_run_id 是 writable 属性但不在任何公开 action 的 accept——只有本 action 可写。
    update :link_research_run do
      description("回写教研 workflow 产物引用（#39 实例化后）")
      require_atomic?(false)
      accept([:workflow_run_id])
    end

    # #40 展示页：按 id 取课程详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end

    # E-5 #50 公开宿主页：按 slug 取详情（全局唯一，公开路由无 workspace 前缀）
    read :get_by_slug do
      get_by([:slug])
    end
  end

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）──

  def launched_payload(_changeset, course) do
    %{
      "course_id" => course.id,
      "title" => course.title,
      "research_requirements" => course.research_requirements || %{}
    }
  end

  def ended_payload(_changeset, course),
    do: %{"course_id" => course.id, "title" => course.title}

  # DB 级 compare-and-set：条件 UPDATE 原子抢占状态迁移（enrollment.expire 同款
  # 纪律）。num_rows=0 → 并发竞态（cron 与手动双拍），拒绝而非双成功双发布。
  # 成功后由调用方 force_change（Ash 后续写同值幂等，返回 record 状态正确）。
  defp status_transition(changeset, to_status) do
    sql = "UPDATE courses SET status = $1, updated_at = NOW() WHERE id = $2 AND status = $3"
    id = Ash.Changeset.get_data(changeset, :id)
    from_status = Ash.Changeset.get_data(changeset, :status)

    case Repo.query(sql, [to_string(to_status), Repo.uuid!(id), to_string(from_status)]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, :status_race}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  postgres do
    table("courses")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取：成员可读非 draft；Owner/Admin 与平台管理员可读全部；
    # 匿名仅可读 open + visibility=public（公开发现面，D2 白名单由 field_policies 收窄）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.ActorReadsOffering)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
      authorize_if(expr(status == :open and visibility == :public))
    end

    # 写操作：Owner/Admin（多角色并集）
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  # D2 公开字段白名单（denylist 式，Ash field_policy 为 AND 语义：:* 恒放行，
  # 敏感字段另立 member-or-admin policy 收窄）。非白名单 = workspace_id /
  # research_requirements / workflow_run_id / capacity /
  # confirmed_count，匿名被筛除。
  field_policies do
    field_policy :* do
      authorize_if(always())
    end

    field_policy [
      :workspace_id,
      :research_requirements,
      :workflow_run_id,
      :capacity,
      :confirmed_count
    ] do
      authorize_if({Cgc2046.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:course)
    # U8/R12:教研状态露出(run 状态行)
    relationships([:workflow_run])

    queries do
      list(:list_courses, :read, description: "工作台的课程列表（#40 展示页）")
      read_one(:get_course, :get_by_id, description: "按 id 获取课程（#40）")
      read_one(:get_course_by_slug, :get_by_slug, description: "按 slug 获取（E-5 公开宿主页）")
    end

    mutations do
      create(:create_course, :create)
      update(:update_course, :update)
      update(:launch_course, :launch)
      update(:close_course, :close)
      update(:cancel_course, :cancel)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:events)
    label_field(:title)

    table_columns([
      :id,
      :workspace_id,
      :title,
      :status,
      :capacity,
      :confirmed_count,
      :registration_deadline,
      :inserted_at
    ])
  end
end
