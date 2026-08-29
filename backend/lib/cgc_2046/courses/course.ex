defmodule Cgc2046.Courses.Course do
  @moduledoc """
  课程资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型（docs/01-定稿设计/领域模型定稿.md §5.2 ER）：Course 与 Event 字段同构
  （线上课程，无 venue 场地字段；starts_at/ends_at 语义为开课/结课），教研字段一致。
  Phase 2 加入报名策略、容量与报名截止时间；
  `confirmed_count` 为账本投影：原子占位由 Admission.CapacityLedger 条件 UPDATE 承担，本字段经 capacity.synced 信号覆盖式投影跟随。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `course.launched` 信号（SignalEmitter 事务内
  outbox 入队，SignalPublishWorker 经 JidoAdapter 总线异步投递），
  `Cgc2046.Curriculum.Instantiator` 订阅该信号创建教研 WorkflowRun。

  ## 课程教研流程（role-agent-journeys-v2 S5，R22-R28）

  `create` action：发 `course.created` 信号（同事务内 outbox），
  `Cgc2046.Curriculum.PrepInstantiator` 订阅幂等实例化 course_preparation
  WorkflowRun（prep_state 状态机在 run facts 内，见 `Cgc2046.Curriculum.Prep`）。
  `launch` 带教研门：存在未走完的 prep run 时拒绝带外发布，发布由教研流程的
  发布步经 changeset context `via_prep: true` 放行；存量无 prep run 课程放行。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Courses

  alias Cgc2046.StatusTransition
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
      description: "课程标题；create 缺省时由 change 生成临时占位标题（未命名课程 <hex8>，见 provisional_title），读取面恒非空"
    )

    attribute(:provisional_title, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: false,
      description: "当前标题是否为系统生成的临时占位（role-agent-journeys-v2 S3 零输入草稿，R21/AE1）；设置真实标题即清除，发布前置门"
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

    attribute(:curriculum_requirements, :map,
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

    attribute(:current_revision_id, :uuid,
      # S6-03（advisor R1）：非公共——内部发布指针无公共 GraphQL 消费方，
      # public?: true 会把 output/filter/sort 面扩进公开 SDL（外部消费者形成
      # 依赖后移除即 breaking）。读取 = 域代码（published_content/1）与
      # :bind_current_revision 端口，不经 API 面。
      public?: false,
      writable?: true,
      description: "当前 published 课程版本（S6 R29：教研发布步经端口写入；nil = 从未经教研流程发布的存量课程）"
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
      # ADR-0009 U7 起为展示投影（Courses 自订阅 capacity.synced 自写本列；权威计数
      # 在 Admission 名额账本 occupancy）。description 永久冻结旧文案（U8 裁决）：
      # 公开 SDL 零 diff 门（R8/KTD3）优先于文案更正，正确语义以本注释与
      # CONTEXT.md 名额账本词条为准
      description: "已确认名额数（仅由 Enrollment 原子维护）"
    )

    attribute(:confirmed_count_sync_version, :integer,
      allow_nil?: false,
      default: 0,
      public?: false,
      writable?: false,
      description: "confirmed_count 投影已应用的账本 sync_version（只接受更大版本，覆盖式幂等 + 乱序收敛）"
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
    validate({Cgc2046.Offering.PriceTiersValidation, []})
    validate({Cgc2046.Offering.ScheduleValidation, []})
  end

  calculations do
    # R2 报名面：只暴露未过 available_until 的档位（过滤逻辑在 PriceTier）。
    # load: GraphQL 单独请求本计算字段时 ash_graphql 不自动 select 依赖列,
    # price_tiers 落 NotLoaded → available_tiers 误判空(load 依赖声明后由 Ash 补载)。
    calculate(:available_price_tiers, {:array, :map},
      public?: true,
      load: [:price_tiers],
      calculation: fn records, _opts ->
        Enum.map(records, &Cgc2046.Offering.PriceTier.available_tiers(&1.price_tiers))
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
        Enum.map(records, &Cgc2046.Offering.EnrollmentBadge.badge(&1, now))
      end
    )
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
      :curriculum_requirements,
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
        :curriculum_requirements,
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

      # S3 零输入草稿（R21/AE1）：title 缺省时生成可辨识临时占位标题并打
      # provisional_title 标记；Tutor 发布前必须补名（launch 命名门拦截）。
      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :title) do
          value when is_binary(value) and value != "" ->
            changeset

          _ ->
            suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

            changeset
            |> Ash.Changeset.force_change_attribute(:title, "未命名课程 " <> suffix)
            |> Ash.Changeset.force_change_attribute(:provisional_title, true)
        end
      end)

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

      # role-agent-journeys-v2 S5 课程教研流程（R22）：课程创建即发 course.created
      # 信号（事务内 outbox，与 course.launched 同一 SignalEmitter 纪律；emitter 注入
      # 幂等键 course.created:<course_id>），Curriculum.PrepInstantiator 订阅幂等
      # 实例化 prep run——每门新课程恰有一个教研流程 run。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "course.created", payload: &__MODULE__.created_payload/2}
      )
    end

    # 编辑课程元数据（E-11 #127）：visibility 可随时双向切换（含 open 后，D9）。
    # status/workflow_run_id/confirmed_count 不在此 accept（状态走专用 action）。
    update :update do
      description("编辑课程元数据（Owner/Admin）")
      require_atomic?(false)

      accept([
        :title,
        :curriculum_requirements,
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

      # S3：设置真实标题即清除临时占位标记（provisional_title 不可由调用方直写）
      change(fn changeset, _context ->
        case Ash.Changeset.fetch_change(changeset, :title) do
          {:ok, value} when is_binary(value) and value != "" ->
            Ash.Changeset.force_change_attribute(changeset, :provisional_title, false)

          _ ->
            changeset
        end
      end)

      # R9 关闭收费批量免费确认（organizer-payment U3，KTD4）：true→false 时
      # 同事务对 payment_pending 报名逐条复用免缴三元组。
      change({Cgc2046.Admission.Changes.WaivePendingOnPricingDisable, kind: :course})

      # R16/KTD4（ADR-0009 PR⑤ U6）：capacity / registration_deadline 变更发
      # offering.capacity_changed，名额账本订阅方回查 Offering 同步缓存
      # （event.ex :update 同款；payload 不扩字段，订阅方回读最新值）。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "offering.capacity_changed",
         payload: &__MODULE__.capacity_changed_payload/2,
         skip_unless: &__MODULE__.capacity_or_deadline_changed?/2}
      )
    end

    # draft → open：发布课程，发 course.launched 信号（教研实例化入口）。
    # 信号经 SignalEmitter 事务内 outbox 入队，SignalPublishWorker 提交后异步
    # 投递——订阅方读到的必是已提交 open 状态（#1 TOCTOU 由 outbox 结构性解决，
    # 不再有 for_update 阶段发布读未提交 draft 的窗口）。
    update :launch do
      description("发布课程：draft → open，发 course.launched 信号")
      require_atomic?(false)
      accept([])

      # S3 命名门（R21/AE1）：临时占位标题的课程不得发布——先经 update 设置正式
      # 标题。域名层拦截（非仅工具层），GraphQL/MCP 同语义。
      change(fn changeset, _context ->
        if Ash.Changeset.get_data(changeset, :provisional_title) do
          Ash.Changeset.add_error(
            changeset,
            "课程尚未命名，不能发布：请先设置正式课程标题（当前为系统生成的临时标题）"
          )
        else
          changeset
        end
      end)

      # S5 教研门（R23/R28）：课程存在 course_preparation run 且教研流程未走完
      # （prep_state != published）时，带外发布（web/GraphQL/MCP launch_course）
      # 一律拒绝——发布只能由教研流程的发布步触发。发布步经 changeset context
      # `via_prep: true` 放行（context 只能由后端调用方注入，GraphQL/MCP 参数面
      # 无法伪造，§B#10）；无 prep run 的课程（本特性前的存量课程）照常发布。
      change(fn changeset, _context ->
        if changeset.context[:via_prep] == true do
          changeset
        else
          case Cgc2046.Curriculum.Prep.fetch_run(
                 Ash.Changeset.get_data(changeset, :id),
                 Ash.Changeset.get_data(changeset, :workspace_id)
               ) do
            nil ->
              changeset

            run ->
              if Cgc2046.Curriculum.Prep.prep_state(run) == "published" do
                changeset
              else
                Ash.Changeset.add_error(changeset, "课程须完成教研流程后发布")
              end
          end
        end
      end)

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
        {Cgc2046.Workflows.SignalEmitter,
         type: "course.launched", payload: &__MODULE__.launched_payload/2}
      )

      # GO/NO-GO（D3 警告放行）：清单非 ready 记 warning 不阻塞发布，
      # 明细经 GraphQL readiness 查询暴露后台（event.launch 同款，Readiness 统一）。
      change(after_transaction(&Cgc2046.Offering.Readiness.warn_unless_ready/3))
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
        {Cgc2046.Workflows.SignalEmitter,
         type: "course.ended", payload: &__MODULE__.ended_payload/2}
      )

      # S6-02（advisor R1）：terminal 收口——同事务取消非终态 prep run
      # （closed/cancelled 课程无法再发布，遗留 active run 只会成为孤儿；
      # 收口失败整体回滚，与状态迁移原子）。经 Curriculum.Prep 域服务
      # （WorkflowRun :cancel 接口，warn 抑制同 launch 端口纪律）。
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, course ->
          case Cgc2046.Curriculum.Prep.stop_active_runs(course) do
            :ok -> {:ok, course}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
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
        {Cgc2046.Workflows.SignalEmitter,
         type: "course.ended", payload: &__MODULE__.ended_payload/2}
      )

      # S6-02（advisor R1）：terminal 收口——同事务取消非终态 prep run
      # （closed/cancelled 课程无法再发布，遗留 active run 只会成为孤儿；
      # 收口失败整体回滚，与状态迁移原子）。经 Curriculum.Prep 域服务
      # （WorkflowRun :cancel 接口，warn 抑制同 launch 端口纪律）。
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, course ->
          case Cgc2046.Curriculum.Prep.stop_active_runs(course) do
            :ok -> {:ok, course}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)
    end

    defaults([:read])

    # #14：教研 run 创建后回写产物引用（Curriculum.Instantiator 内部调用，authorize?: false）。
    # workflow_run_id 是 writable 属性但不在任何公开 action 的 accept——只有本 action 可写。
    update :link_curriculum_run do
      description("回写教研 workflow 产物引用（#39 实例化后）")
      require_atomic?(false)
      accept([:workflow_run_id])
    end

    # S6：发布步绑定当前 published 版本（发布端口 bind_revision_for_publish/3 内部
    # 调用，authorize?: false）。current_revision_id 是 writable 属性但不在任何
    # 公开 action 的 accept——只有本 action 可写。
    update :bind_current_revision do
      description("回写当前 published 课程版本（S6 发布步）")
      require_atomic?(false)
      accept([:current_revision_id])
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
      # ADR-0009 KD8/R9：payload 键逐字节冻结，键名不随属性改名
      "research_requirements" => course.curriculum_requirements || %{}
    }
  end

  # S5：course.created 信号 payload（课程教研流程实例化入口；title 此时可能是
  # 临时占位标题——provisional_title 课程也走完整教研流程，发布才被门禁拦截）
  def created_payload(_changeset, course) do
    %{"course_id" => course.id, "title" => course.title}
  end

  def ended_payload(_changeset, course),
    do: %{"course_id" => course.id, "title" => course.title}

  # offering.capacity_changed（R16）：仅 course_id 锚定，缓存值由订阅方回查；
  # 幂等键自带逐次唯一判别子（同课程多次变更各自独立去重，键集合不变仅值唯一化）。
  def capacity_changed_payload(_changeset, course),
    do: %{
      "course_id" => course.id,
      "idempotency_key" =>
        "offering.capacity_changed:#{course.id}:#{System.unique_integer([:positive])}"
    }

  # SignalEmitter skip_unless 谓词：capacity / registration_deadline 任一变更为信号触发
  def capacity_or_deadline_changed?(changeset, _course) do
    Ash.Changeset.changing_attribute?(changeset, :capacity) or
      Ash.Changeset.changing_attribute?(changeset, :registration_deadline)
  end

  # ── 发布端口与公开内容读面（S6，R29；端口范式 = Order.void_pending_for_enrollment）──

  @doc """
  发布端口（Curriculum.Prep.publish 发布事务内调用；本计划唯一新增跨 context
  端口，plan §C）：绑定 `current_revision_id`，课程仍 draft 时 launch
  （`via_prep: true` changeset context 放行教研门，§B#10），已 open 则只换绑
  不重复 launch（次周期发布）。closed/cancelled 课程经 launch 前置拒绝整体
  回滚（发布事务由调用方持有——本端口不开隐式事务）。

  launch/complete 是发布步的系统效应（授权已在 MCP 工具层完成），
  `authorize?: false` 执行；域校验（命名门/教研门/CAS/信号）照常。
  """
  @spec bind_revision_for_publish(t(), Cgc2046.Curriculum.CourseRevision.t(), term()) ::
          {:ok, t()} | {:error, String.t()}
  def bind_revision_for_publish(%__MODULE__{} = course, revision, actor) do
    with {:ok, course} <- bind_current_revision(course, revision),
         {:ok, course} <- maybe_launch_for_publish(course, actor) do
      {:ok, course}
    end
  end

  defp bind_current_revision(
         %__MODULE__{} = course,
         %Cgc2046.Curriculum.CourseRevision{} = revision
       ) do
    course
    |> Ash.Changeset.for_update(:bind_current_revision, %{current_revision_id: revision.id},
      tenant: course.workspace_id
    )
    |> Ash.update(tenant: course.workspace_id, authorize?: false)
    |> case do
      {:ok, course} -> {:ok, course}
      {:error, _} -> {:error, "failed to bind current course revision"}
    end
  end

  # 课程仍 draft → launch（发布即公开）；已 open（次周期发布）→ 只换绑。
  # 其余状态由 launch 的状态前置拒绝（同事务回滚）。
  defp maybe_launch_for_publish(%__MODULE__{status: :open} = course, _actor), do: {:ok, course}

  defp maybe_launch_for_publish(%__MODULE__{} = course, actor) do
    course
    |> Ash.Changeset.for_update(:launch, %{},
      tenant: course.workspace_id,
      context: %{via_prep: true}
    )
    # 发布步刻意单事务（plan §B#9）：launch 的 after_transaction 钩子（SignalEmitter
    # 事务内 outbox + Readiness 警告）皆为同连接事务内 DB 写/日志，随外层事务
    # 回滚而回滚——抑制「外裹事务」警告。
    |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
    |> Ash.update(tenant: course.workspace_id, actor: actor, authorize?: false)
    |> case do
      {:ok, launched} ->
        {:ok, launched}

      # Ash 3 失败返回 changeset 或 Invalid——归一为字符串（发布事务回滚契约）
      {:error, %Ash.Changeset{errors: errors}} when errors != [] ->
        {:error, Enum.map_join(errors, ", ", &Exception.message/1)}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      {:error, _} ->
        {:error, "failed to launch course"}
    end
  end

  # S6（R29）：公开读面（courseMap）的内容源 = 当前 published CourseRevision——
  # 发布即冻结，草稿后续编辑不影响公开面；current_revision_id 为 nil 的存量
  # 课程（从未经教研流程发布）回退 Curriculum.course_content/1 活文档草稿。
  # authorize?: false 纪律同 Curriculum.course_content/1（门禁在调用面，
  # 内容投影由调用方负责）。
  @doc false
  def published_content(%__MODULE__{current_revision_id: revision_id, workspace_id: workspace_id})
      when is_binary(revision_id) and is_binary(workspace_id) do
    case Cgc2046.Curriculum.revision_by_id(workspace_id, revision_id) do
      {:ok, %{content: content}} -> content
      _ -> nil
    end
  end

  def published_content(%__MODULE__{} = course), do: Cgc2046.Curriculum.course_content(course)

  def published_content(_course), do: nil

  # 状态机 CAS 委托根部共享写原语（ADR-0009 D5 迁出 offering/，KTD2）。
  defp status_transition(changeset, to_status),
    do: StatusTransition.run(changeset, :courses, to_status)

  postgres do
    table("courses")
    repo(Cgc2046.Repo)
  end

  policies do
    # 读取：成员可读非 draft；Owner/Admin 与平台管理员可读全部；
    # 匿名仅可读 open + visibility=public（公开发现面，D2 白名单由 field_policies 收窄）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Offering.ActorReadsOffering)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(status == :open and visibility == :public))
    end

    # 写操作：Owner/Admin（多角色并集）
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end

  # D2 公开字段白名单（denylist 式，Ash field_policy 为 AND 语义：:* 恒放行，
  # 敏感字段另立 member-or-admin policy 收窄）。非白名单 = workspace_id /
  # curriculum_requirements / workflow_run_id / capacity /
  # confirmed_count / provisional_title（S3 起新字段排除匿名可见，计划 §A
  # 纪律），匿名被筛除。current_revision_id 非公共属性（S6-03：无 API 面，
  # 无需 field_policy——confirmed_count_sync_version 同款一致性）。
  field_policies do
    field_policy :* do
      authorize_if(always())
    end

    field_policy [
      :workspace_id,
      :curriculum_requirements,
      :workflow_run_id,
      :capacity,
      :confirmed_count,
      :provisional_title
    ] do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
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
    resource_group(:courses)
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
