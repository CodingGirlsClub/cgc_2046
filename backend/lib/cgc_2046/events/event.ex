defmodule Cgc2046.Events.Event do
  @moduledoc """
  活动资源（Slice C #39，阶段 6 教研实例化最小子集）。

  领域模型：Event 是活动实体，
  教研字段之外，Phase 2 加入报名策略、容量与报名截止时间。`confirmed_count`
  是账本（Admission.CapacityLedger）投影：创建/确认的原子占位由账本条件 UPDATE 承担（防超卖唯一权威），confirmed_count 经 capacity.synced 信号覆盖式投影跟随。

  ## 教研实例化（#39）

  `launch` action：draft → open，发 `event.launched` 信号（SignalEmitter 事务内
  outbox 入队，SignalPublishWorker 经 JidoAdapter 总线异步投递），
  `Cgc2046.Curriculum.Instantiator` 订阅该信号创建教研 WorkflowRun。

  ## 多租户

  multitenancy attribute :workspace_id，与 WorkflowRun 一致；workspace_id 由 tenant
  强制，不接受调用方传入。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Events

  alias Cgc2046.Errors.ConstraintConflict
  alias Cgc2046.Events.PaymentModeValidation
  alias Cgc2046.StatusTransition
  @status_values [:draft, :open, :closed, :cancelled]

  # 合法状态枚举的对外读面（list_workspace_events 过滤校验消费；
  # @doc false public 先例同 Course.status_values）
  @doc false
  @spec status_values() :: [atom()]
  def status_values, do: @status_values

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
      description: "活动标题"
    )

    attribute(:slug, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一）"
    )

    attribute(:description, :string,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "公开展示文案（可空；null 由展示层按空串呈现）"
    )

    attribute(:curriculum_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否启用教研 workflow"
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
      description: "活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消"
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
      # ADR-0009 U7 起为展示投影（Events 自订阅 capacity.synced 自写本列；权威计数
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
      description: "活动开始时间；nil 表示未定（R1）"
    )

    attribute(:ends_at, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1）"
    )

    attribute(:venue, :map,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定"
    )

    attribute(:course_revision_id, :uuid,
      allow_nil?: true,
      public?: false,
      writable?: true,
      description:
        "配套课程锚点（issue #505 D1）：指向一门普通课程的 published revision；" <>
          "nil = 无配套课（宣讲会）。公开读面经 companionCourse 计算字段投影，" <>
          "属性本身不进公开 SDL（courses.current_revision_id 同款纪律）"
    )

    attribute(:initiative_id, :uuid,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "所属平台级 Initiative；仅草稿可挂载"
    )

    # #624 解除挂载语义（方案 C）：detach 不回收平台锁死规则强制写入的值（值留在
    # Event 上、回归普通可编辑字段），本列记录这些值「来自哪个 Initiative 的哪条
    # 锁死规则」——只描述「已解除挂载后仍留在场上的强制值」，形状与 #596 写响应
    # `applied` 同源：
    #
    #   %{"initiative" => %{"id" =>, "name" =>, "slug" =>},
    #     "fields" => %{"min_age" => %{"value" => 18, "source" => "locked"}, ...}}
    #
    # 生命周期（全在 RuleInheritance.prepare_event_changes/2 同一事务内）：
    # detach 时写入（无 locked 字段 → nil）；场主首次改写标记内字段 → 逐字段清除，
    # 键空 → 整列 nil；重挂载 → 整列清空（值重新归新 Initiative 治理）。
    # writable?: false：只由挂载边界写，客户端不可直接设置（治理数据）。
    # filterable?/sortable? false：只读输出面，不做查询/排序维度（避免把
    # jsonb 治理标记扩进 EventFilterInput / EventSortField）。
    attribute(:detached_rule_provenance, :map,
      allow_nil?: true,
      public?: true,
      writable?: false,
      filterable?: false,
      sortable?: false,
      description: "解除挂载时保留的锁死规则来源标记（nil = 无；场主改写对应字段后逐字段清除）"
    )

    attribute(:created_by, :uuid, allow_nil?: true, public?: true, writable?: false)

    attribute(:deposit_enabled, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      writable?: true,
      description: "是否收取活动押金（与既有报名定价分开）"
    )

    attribute(:deposit_amount_cents, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "押金金额（分）"
    )

    attribute(:min_age, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "报名最低年龄；nil 表示无年龄门槛"
    )

    attribute(:min_participants, :integer,
      allow_nil?: true,
      public?: true,
      writable?: true,
      constraints: [min: 1],
      description: "成班最低确认人数；nil 表示不判定成班"
    )

    attribute(:qualification_status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [one_of: [:pending, :confirmed, :underfilled]],
      description: "成班事实：pending / confirmed / underfilled"
    )

    attribute(:sponsorship_enabled, :boolean,
      allow_nil?: false,
      default: true,
      public?: true,
      writable?: true,
      description: "是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②）"
    )

    attribute(:sponsorship_tiers, {:array, :map},
      allow_nil?: false,
      default: [],
      public?: true,
      writable?: true,
      description: "赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex）"
    )

    attribute(:sponsorship_deadline, :utc_datetime,
      allow_nil?: true,
      public?: true,
      writable?: true,
      description: "赞助意向截止；nil 表示长期开放"
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
    validate({Cgc2046.Accounts.SponsorshipTiersValidation, []})
    validate({Cgc2046.Offering.PriceTiersValidation, []})
    validate({Cgc2046.Events.VenueValidation, []})
    validate({Cgc2046.Events.CompanionRevisionValidation, []})
    validate({Cgc2046.Offering.ScheduleValidation, []})
    # 缴费三态互斥（KTD3 / R1 / R3）：免费 / 定价 / 押金单选；押金开启
    # 必须正金额 + 非空 ends_at（no-show 结算锚点）。并发兜底 =
    # postgres.check_constraints 的 events_payment_mode_exclusive。
    validate({Cgc2046.Events.PaymentModeValidation, []})

    # slug 单段 URL 约束（create/update 同规则；#619 从 create/update 各自内联的
    # action change 收敛为资源级单源）。only_when_valid?（同 Initiative #588）：
    # slug 锁定守卫是 action change，先于本 validation 跑——非 draft 传
    # 「又非法又锁定」的 slug 只回一个 event_slug_locked，不叠加格式错把人
    # 骗进「改好格式再来」的死循环（再来仍被锁）。
    validate(match(:slug, ~r/^[a-z0-9][a-z0-9-]*$/),
      only_when_valid?: true,
      message: "slug must be a single lowercase URL segment ([a-z0-9-])"
    )
  end

  calculations do
    calculate(:qualification_badge, :string,
      public?: true,
      load: [:status, :qualification_status, :min_participants],
      calculation: fn records, _ ->
        Cgc2046.Events.QualificationBadge.project(records, :qualification_badge)
      end
    )

    calculate(:short_by, :integer,
      public?: true,
      load: [:status, :qualification_status, :min_participants],
      calculation: fn records, _ ->
        Cgc2046.Events.QualificationBadge.project(records, :short_by)
      end
    )

    # issue #505 D1 公开读面：配套课程卡投影（id/slug/title 最小集；无锚 →
    # nil）。load 依赖声明同 available_price_tiers 纪律（GraphQL 单独请求时
    # Ash 补载 course_revision_id）。
    calculate(:companion_course, :map,
      public?: true,
      load: [:course_revision_id],
      description: "配套课程投影（JsonString 序列化的 {id, slug, title}；null = 无配套课/宣讲会）",
      calculation: fn records, _opts ->
        Cgc2046.Events.CompanionCourse.project(records)
      end
    )

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

    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun,
      source_attribute: :workflow_run_id,
      destination_attribute: :id,
      allow_nil?: true
    )

    belongs_to(:initiative, Cgc2046.Initiatives.Initiative,
      source_attribute: :initiative_id,
      destination_attribute: :id,
      allow_nil?: true,
      define_attribute?: false
    )

    has_many(:moderators, Cgc2046.Events.EventModerator, destination_attribute: :event_id)
  end

  actions do
    default_accept([
      :title,
      :curriculum_enabled,
      :curriculum_requirements,
      :enrollment_policy,
      :capacity,
      :registration_deadline,
      :starts_at,
      :ends_at,
      :venue,
      :visibility,
      :slug,
      :description,
      :sponsorship_enabled,
      :sponsorship_tiers,
      :sponsorship_deadline,
      :pricing_enabled,
      :price_tiers,
      :course_revision_id,
      :initiative_id,
      :deposit_enabled,
      :deposit_amount_cents,
      :min_age,
      :min_participants
    ])

    create :create do
      description("创建活动（默认 status=draft）")

      accept([
        :title,
        :curriculum_enabled,
        :curriculum_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :starts_at,
        :ends_at,
        :venue,
        :visibility,
        :slug,
        :description,
        :sponsorship_enabled,
        :sponsorship_tiers,
        :sponsorship_deadline,
        :pricing_enabled,
        :price_tiers,
        :course_revision_id,
        :initiative_id,
        :deposit_enabled,
        :deposit_amount_cents,
        :min_age,
        :min_participants
      ])

      # GraphQL 入口不注入 tenant（#104 同款），workspace_id 由入参提供；
      # 内部调用方（fixtures/测试）直接传 tenant 亦可。policy 经
      # MembershipContext 的 argument 回退解析工作台（invitation.ex 同款先例）。
      argument(:workspace_id, :uuid,
        allow_nil?: true,
        description: "目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略）"
      )

      change(set_attribute(:status, :draft))

      # 缴费互斥 DB CHECK（并发兜底，KTD3）冲突转稳定业务错误
      error_handler({__MODULE__, :handle_write_error, []})

      change(fn changeset, context ->
        changeset
        |> Ash.Changeset.before_action(fn cs ->
          Cgc2046.Initiatives.RuleInheritance.prepare_event_changes(cs, context)
        end)
        |> Cgc2046.Initiatives.RuleInheritance.attach_inheritance_metadata()
      end)

      change(fn changeset, _context ->
        case Kernel.get_in(changeset.context, [:private, :actor]) do
          %{id: user_id} -> Ash.Changeset.force_change_attribute(changeset, :created_by, user_id)
          _ -> changeset
        end
      end)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, event ->
          result =
            case Kernel.get_in(cs.context, [:private, :actor]) do
              %{id: user_id} -> Cgc2046.Events.Moderators.ensure_assigned(event, user_id)
              _ -> :ok
            end

          case result do
            :ok -> {:ok, event}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)

      # slug 未提供时兜底生成（公开 URL 段；唯一索引防碰撞）
      change(fn changeset, _context ->
        changeset =
          case Ash.Changeset.get_attribute(changeset, :slug) do
            value when is_binary(value) and value != "" ->
              changeset

            _ ->
              suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
              Ash.Changeset.force_change_attribute(changeset, :slug, "e-" <> suffix)
          end

        changeset
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

    # 编辑活动元数据（E-11 #127）：visibility 可随时双向切换（含 open 后，D9）。
    # status/workflow_run_id/confirmed_count 不在此 accept（状态走专用 action）。
    update :update do
      description("编辑活动元数据（Owner/Admin）")
      require_atomic?(false)

      accept([
        :title,
        :curriculum_enabled,
        :curriculum_requirements,
        :enrollment_policy,
        :capacity,
        :registration_deadline,
        :starts_at,
        :ends_at,
        :venue,
        :visibility,
        :slug,
        :description,
        :sponsorship_enabled,
        :sponsorship_tiers,
        :sponsorship_deadline,
        :pricing_enabled,
        :price_tiers,
        :course_revision_id,
        :initiative_id,
        :deposit_enabled,
        :deposit_amount_cents,
        :min_age,
        :min_participants
      ])

      # 缴费互斥 DB CHECK（并发兜底，KTD3）冲突转稳定业务错误
      error_handler({__MODULE__, :handle_write_error, []})

      change(fn changeset, context ->
        changeset
        |> Ash.Changeset.before_action(fn cs ->
          Cgc2046.Initiatives.RuleInheritance.prepare_event_changes(cs, context)
        end)
        |> Cgc2046.Initiatives.RuleInheritance.attach_inheritance_metadata()
      end)

      # 强制非原子执行：GraphQL update 走 bulk_update（原子路径）时 policy 的
      # changeset.data 读取会 raise（AtomicChangeset 无原数据）。本函数 change
      # 使 action 原子能力判定失败，回落到带原数据的常规 update 路径。
      change(fn changeset, _context ->
        _ = Ash.Changeset.get_data(changeset, :status)
        changeset
      end)

      # 发布后 slug 锁定（2026-09-08 拍板，ADR-0014）：公开 URL 段发布即契约——
      # 已分发链接（微信 scheme / 邀请邮件内嵌 URL / 社群粘贴）不随改名 404。
      # draft 随便改；无 rename 后门（D4 终态语义同款：恢复路径 = 新建）。
      # #619：裸 add_error 落 GraphQL 只有 invalid_attribute（不在 #241 契约、
      # 两端无文案），改 BusinessError 稳定 code event_slug_locked（Initiative
      # #588 同款）。排障不再需要 value 通道——code 即「锁定拦截」的判据。
      # 同值回传不算变更：非 draft 表单 disabled 仍回传旧 slug 时，
      # Ash.Changeset.do_change_attribute 同值删键，changing_attribute? 不误触发。
      # 格式校验已收敛为资源级 validation（only_when_valid?）——锁定优先于格式错。
      change(fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :slug) and
             Ash.Changeset.get_data(changeset, :status) != :draft do
          Ash.Changeset.add_error(
            changeset,
            Cgc2046.Errors.BusinessError.exception(
              message: "slug is locked once the offering is published (editable in draft only)",
              code: "event_slug_locked",
              fields: [:slug]
            )
          )
        else
          changeset
        end
      end)

      # R9 关闭收费批量免费确认（organizer-payment U3，KTD4）：true→false 时
      # 同事务对 payment_pending 报名逐条复用免缴三元组。
      change({Cgc2046.Admission.Changes.WaivePendingOnFeeSlotDisable, kind: :event})

      # R16/KTD4（ADR-0009 PR⑤ U6）：capacity / registration_deadline 变更发
      # offering.capacity_changed，名额账本订阅方回查 Offering 同步缓存。
      # payload 不扩字段（KTD5：订阅方回读永远拿最新值，优于信号快照）。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "offering.capacity_changed",
         payload: &__MODULE__.capacity_changed_payload/2,
         skip_unless: &__MODULE__.capacity_or_deadline_changed?/2}
      )

      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "event.schedule_changed",
         payload: &__MODULE__.schedule_changed_payload/2,
         skip_unless: &__MODULE__.schedule_changed_and_published?/2}
      )
    end

    # ensure_launched 守卫会静默丢弃实例化。提交后发布，订阅方读到 open。
    update :launch do
      description("发布活动：draft → open，发 event.launched 信号")
      require_atomic?(false)
      accept([])

      # #628 Initiative 生命周期门：挂载中的场只有在所属 Initiative 仍 open 时
      # 才能发布。声明在 CAS change **之前**——Ash `run_before_actions` 在
      # changeset 失效处 `:halt`（ash/changeset/changeset.ex 的 reduce_while），
      # 故此门拒绝时下面的条件 UPDATE 根本不执行（不会先写库再回滚）。
      change(fn changeset, _context ->
        Ash.Changeset.before_action(
          changeset,
          &Cgc2046.Initiatives.RuleInheritance.ensure_launchable/1
        )
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

      # event.launched 经 SignalEmitter 事务内 outbox 入队（plan 2026-08-14-003
      # Q6）：job 与 open 终态同事务提交，SignalPublishWorker 提交后异步投递——
      # 订阅方读到的必是已提交 open 状态（#1 TOCTOU 由 outbox 结构性解决）。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "event.launched", payload: &__MODULE__.launched_payload/2}
      )

      # GO/NO-GO（D3 警告放行）：清单非 ready 记 warning 不阻塞发布，
      # 明细经 GraphQL readiness 查询暴露后台（course.launch 同款，Readiness 统一）。
      change(after_transaction(&Cgc2046.Offering.Readiness.warn_unless_ready/3))
    end

    # open → closed：结束活动（手动，或 registration_deadline 到点由
    # EventLifecycleWorker 自动执行）。发 event.ended 信号——E-9 #124 级联：
    # 订阅方 = 教研 run 回收 / 赞助 Event 级自动 ended / 报名窗锁定。
    # 终态不可逆（D4 v1 语义）：closed/cancelled 无恢复 action，恢复路径 =
    # 新建活动。DB 级 compare-and-set 防陈旧/并发双成功（cron 与手动竞态，
    # codex 评审 BLOCKING 4）。
    update :close do
      description("结束活动：open → closed，发 event.ended 信号")
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

      # event.ended 经 SignalEmitter 事务内 outbox 入队：job 与事件终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "event.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    # open → cancelled：取消活动。同样发 event.ended（D4：closed/cancelled 即 ended）。
    update :cancel do
      description("取消活动：open → cancelled，发 event.ended 信号")
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

      # event.ended 经 SignalEmitter 事务内 outbox 入队：job 与事件终态同事务提交，
      # 入队失败回滚可安全重试；CAS 失败路径不到 after_action，不产生孤儿 job。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: "event.ended", payload: &__MODULE__.ended_payload/2}
      )
    end

    # draft-only 删除（#676，ADR-0015；级联完备性 #688 修订）：与 Course :delete
    # 同款（行锁守卫 + 状态裁决 + slug 释放 + 同事务级联）。
    #
    # 级联分三类（#688 按事实重写，原「无级联」论证被证伪——讲者邀请 run 在
    # **邀请创建时**实例化（draft 合法，speaker_invitation.ex 的状态门放行
    # :draft），不是 launch 后）：
    #
    # - 结构性不存在：教研 curriculum run（launch 后由 Instantiator 创建）、
    #   内容行（curriculum_outputs 只有 course 维度）、enrollments / attendances
    #   （报名需 offering open；attendances 无 on_delete，异常存在即 DELETE 被 FK
    #   拒绝，fail-closed 不静默丢数据）。
    # - FK 承接（on_delete: delete_all，迁移侧无需改动）：event_moderators /
    #   sponsorships / speaker_invitations / invite_batches（后两者对 draft 并非
    #   结构性不存在——邀请在 draft 合法、批次创建无状态门，故 MCP 摘要须披露）。
    # - 显式收口（同事务，任一步失败整体回滚）：讲者邀请 run 收口
    #   （SpeakerInvitation.stop_event_runs/1——workflow_runs 无指向 events 的
    #   外键，FK 级联不到 run；非终态 run → cancelled 留痕，facts 保留）+
    #   名额账本行删除（CapacityLedger.delete_for_offering/2——offering_id 多态
    #   无外键；draft 行 occupancy 结构性为 0，reserve 三守卫含 status='open'）。
    #
    # 治理留痕（admin_action_logs / tool_calls）不随业务行删除。
    #
    # 行锁守卫（SELECT … FOR UPDATE）与 slug 释放论证同 Course :delete（见该 action
    # 注释）：status 列是 text，行值即 atom attribute 的 DB 形态（"draft"）。
    destroy :delete do
      description("删除草稿活动：仅 draft；不可恢复；slug 释放（#676）")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          repo = Cgc2046.Repo

          case repo.query("SELECT status FROM events WHERE id = $1 FOR UPDATE", [
                 repo.uuid!(Ash.Changeset.get_data(cs, :id))
               ]) do
            {:ok, %{rows: [["draft"]]}} ->
              cs

            {:ok, %{rows: [[status]]}} ->
              Ash.Changeset.add_error(cs, "cannot delete from status=#{status}")

            {:ok, %{rows: []}} ->
              Ash.Changeset.add_error(cs, "event not found")

            {:error, reason} ->
              Ash.Changeset.add_error(cs, {:database, reason})
          end
        end)
      end)

      # 收口与删除原子（Course :delete 的 stop_active_runs + delete_for_course
      # 同款 with 模板）：失败上抛整体回滚——event 行仍在、run 状态不变（fail-closed）。
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, event ->
          with :ok <- Cgc2046.Events.SpeakerInvitation.stop_event_runs(event),
               :ok <- Cgc2046.Admission.CapacityLedger.delete_for_offering(:event, event.id) do
            {:ok, event}
          end
        end)
      end)
    end

    update :qualify do
      description("在报名截止时一次性落成班事实；仅内部生命周期 worker 使用")
      require_atomic?(false)

      argument(:qualification_status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:confirmed, :underfilled]]
      )

      accept([])

      change(fn changeset, _context ->
        status = Ash.Changeset.get_argument(changeset, :qualification_status)

        if Ash.Changeset.get_data(changeset, :qualification_status) == :pending do
          Ash.Changeset.force_change_attribute(changeset, :qualification_status, status)
        else
          Ash.Changeset.add_error(changeset, "event qualification already settled")
        end
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

    # #40 展示页：按 id 取活动详情（GraphQL read_one）
    read :get_by_id do
      get_by([:id])
    end

    # E-5 #50 公开宿主页：按 slug 取详情（全局唯一，公开路由无 workspace 前缀）
    read :get_by_slug do
      get_by([:slug])
    end

    # list_events 专用（#411/enrollment.ex:177-181 同款）：keyset 分页要求稳定
    # 唯一序，UUID v4 主键时间无序——无显式 sort 时列表顺序契约上无保证。
    # inserted_at desc + id 兜底（同秒平票 tiebreaker 保 keyset 序唯一）。
    read :list_events do
      description("活动列表（graphql list_events；按插入时间倒序）")
      prepare(build(sort: [inserted_at: :desc, id: :asc]))
      # 018：max_page_size 封顶（超出静默 clamp 而非报错，Ash 语义）——
      # 本面 + courses + admin 面 + tool_calls 面已收口；其余 pagination 面
      # （enrollments/myEnrollments/sponsorship/orders）另行收口
      pagination(keyset?: true, default_limit: 250, max_page_size: 250)
    end
  end

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）──

  def launched_payload(_changeset, event) do
    %{
      "event_id" => event.id,
      "title" => event.title,
      # ADR-0009 KD8/R9：payload 键逐字节冻结，键名不随属性改名
      "research_requirements" => event.curriculum_requirements || %{}
    }
  end

  def ended_payload(_changeset, event), do: %{"event_id" => event.id, "title" => event.title}

  # offering.capacity_changed（R16）：仅 event_id 锚定，缓存值由订阅方回查；
  # 幂等键自带逐次唯一判别子（同事件多次变更各自独立去重，键集合不变仅值唯一化）。
  def capacity_changed_payload(_changeset, event),
    do: %{
      "event_id" => event.id,
      "idempotency_key" =>
        "offering.capacity_changed:#{event.id}:#{System.unique_integer([:positive])}"
    }

  # SignalEmitter skip_unless 谓词：capacity / registration_deadline 任一变更为信号触发
  def capacity_or_deadline_changed?(changeset, _event) do
    Ash.Changeset.changing_attribute?(changeset, :capacity) or
      Ash.Changeset.changing_attribute?(changeset, :registration_deadline)
  end

  defp schedule_changed?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :starts_at) or
      Ash.Changeset.changing_attribute?(changeset, :venue)
  end

  @doc false
  def schedule_changed_and_published?(changeset, _event),
    do:
      schedule_changed?(changeset) and
        Ash.Changeset.get_data(changeset, :status) in [:open, "open", :closed, "closed"]

  @doc false
  def schedule_changed_payload(changeset, event) do
    # changed 维度（#565）：消费侧据此分档 debounce 窗口（时间变更 5 分钟 /
    # 场地及其他 15 分钟）。快照字段仅作信号参考值——fanout 投递以回查的
    # event 真状态渲染（latest-wins），不使用这里的快照。
    changed =
      for attr <- [:starts_at, :venue],
          Ash.Changeset.changing_attribute?(changeset, attr),
          do: Atom.to_string(attr)

    %{
      "event_id" => event.id,
      "title" => event.title,
      "starts_at" => event.starts_at,
      "venue" => event.venue,
      "changed" => changed,
      "idempotency_key" => "event.schedule_changed:" <> event.id <> ":" <> Ecto.UUID.generate()
    }
  end

  # 状态机 CAS 委托根部共享写原语（ADR-0009 D5 迁出 offering/，KTD2）。
  defp status_transition(changeset, to_status),
    do: StatusTransition.run(changeset, :events, to_status)

  # create/update error_handler（KTD3 / #597 / #608 / #623 / #619）：缴费模式 DB
  # CHECK 冲突转稳定业务错误。ash_postgres 把 check_constraint DSL 映射为 Ecto
  # check_constraint，冲突落到 InvalidAttribute.private_vars.constraint_type ==
  # :check（约束名在同处 .constraint）——**五条 CHECK + slug 唯一索引全部显式
  # 按名分派**，其余错误原样上抛（fail-closed：新增约束未映射时不吞成某个既有
  # 业务码；enrollment.handle_create_error 同款纪律）。
  # 未进 DSL 的 check 约束（如 events_capacity_positive）在 ash_postgres 侧直接抛
  # Ecto.ConstraintError，到不了本函数。
  def handle_write_error(_changeset, error) do
    cond do
      # 撞 slug 的唯一索引冲突（#619）转稳定业务错误 event_slug_taken（Initiative
      # #604 同款）。按索引名分派（fail-closed）：未来新增其他唯一索引不会被误吞
      # 成 slug_taken。identity :slug 的 ash_postgres 翻译错误仍带
      # private_vars.constraint（enrollment unique_event_user 先例）。
      ConstraintConflict.constraint_named?(error, "events_slug_index") ->
        Cgc2046.Errors.BusinessError.exception(
          message: "slug has already been taken",
          code: "event_slug_taken",
          fields: [:slug]
        )

      ConstraintConflict.constraint_named?(error, "events_deposit_excludes_price_tiers") ->
        PaymentModeValidation.price_tiers_conflict_error(:price_tiers)

      ConstraintConflict.constraint_named?(error, "events_payment_mode_exclusive") ->
        PaymentModeValidation.exclusive_error(:deposit_enabled)

      ConstraintConflict.constraint_named?(
        error,
        "events_deposit_requires_registration_deadline"
      ) ->
        PaymentModeValidation.registration_deadline_required_error()

      ConstraintConflict.constraint_named?(error, "events_deposit_requires_ends_at") ->
        PaymentModeValidation.deposit_ends_at_required_error()

      ConstraintConflict.constraint_named?(error, "events_deposit_requires_positive_amount") ->
        PaymentModeValidation.deposit_amount_required_error()

      ConstraintConflict.constraint_named?(error, "events_pricing_requires_starts_at") ->
        Cgc2046.Offering.PriceTiersValidation.starts_at_required_error()

      true ->
        error
    end
  end

  identities do
    # all_tenants?：slug 全局唯一（公开路由段无 workspace 前缀）；否则 :attribute
    # 多租户会把 workspace_id 并入冲突目标，与 events_slug_index 全局索引不匹配
    # （42P10；Curriculum.CourseRevision.unique_course_number 同款判据）。
    # 名 :slug ↔ 既有索引 events_slug_index，保 generate_migrations --check 零漂移。
    identity(:slug, [:slug], all_tenants?: true)
  end

  postgres do
    table("events")
    repo(Cgc2046.Repo)

    # KTD3 并发兜底：资源校验是友好报错层，两个并发编辑/规则传播各基于
    # 旧值通过时由本 CHECK 拒绝；create/update 的 error_handler 把冲突映射为
    # event_payment_mode_exclusive / event_deposit_price_tiers_conflict /
    # event_deposit_{registration_deadline,ends_at,amount}_required（BusinessError）。
    check_constraints do
      # #543 定价锚点兜底：`pricing_enabled = true` ⇒ `starts_at` 非空（定价单
      # 自助取消「活动开始前全额退」的锚点）。域校验（PriceTiersValidation）只在
      # 相关字段被改动时生效；本 CHECK 无条件兜底新写入（含未知裸 SQL 路径）。
      check_constraint([:pricing_enabled, :starts_at], "events_pricing_requires_starts_at",
        check: "NOT (pricing_enabled AND starts_at IS NULL)",
        message: "starts_at is required when pricing is enabled"
      )

      # message 是同源兜底字面量（与 PaymentModeValidation.exclusive_error/1 同文字；
      # DSL 编译期取值无法引用函数）；用户可见错误由 handle_write_error/2 转换。
      check_constraint([:deposit_enabled, :pricing_enabled], "events_payment_mode_exclusive",
        check: "NOT (deposit_enabled AND pricing_enabled)",
        message: "an event cannot enable both pricing tiers and deposit"
      )

      # #597 I2 并发兜底：押金开 ⇒ 档位为空。域校验见 PaymentModeValidation，
      # 规则挂载/传播路径见 RuleInheritance.merge_event_value/4 与
      # propagate_rule_change/4——本 CHECK 是这两条与未知裸 SQL 的最后兜底。
      # 判据用 `<> '[]'::jsonb` 而非 jsonb_array_length：price_tiers 列
      # NOT NULL DEFAULT '[]'::jsonb，畸形非数组值走 `<>` 也 fail-closed。
      # `NOT pricing_enabled` 是**归因必需**：pricing 开 + 档位非空时本约束不适用，
      # 双真行由 events_payment_mode_exclusive 唯一命中——否则同一行同时违反两条
      # CHECK 时 Postgres 只报其中一条（实测报本条），handle_write_error/2 会把 I1
      # 误报成 I2（既有用例「mount onto pricing-enabled event」钉的就是 I1 归因）。
      # 两条约束不相交 → 任何「押金 + 档位非空」行都恰好命中一条：pricing 开 → I1
      # 约束；pricing 关 → 本约束。与 PaymentModeValidation 的 cond 顺序（I1 先）同序。
      # deposit_enabled 同为 NOT NULL DEFAULT false（无 NULL 分支；若将来放开
      # 可空，CHECK 对 NULL 求值为 NULL = 放行，属预期）。
      # 迁移顺序前置条件：存量违规行必须先由 backfill 迁移清空，否则 NOT VALID
      # 约束仍对该行每次 UPDATE 生效（见两个迁移文件头注释）。
      check_constraint([:deposit_enabled, :price_tiers], "events_deposit_excludes_price_tiers",
        check: "NOT (deposit_enabled AND NOT pricing_enabled AND price_tiers <> '[]'::jsonb)",
        message: "price tiers must be empty when deposit is enabled"
      )

      # #608 / #623 押金锚点兜底：`deposit_enabled = true` ⇒ 报名截止 / ends_at /
      # 正金额三者必须在位（no-show 结算锚点 KTD7 + 自助取消锚点 #587）。
      # 域校验（PaymentModeValidation.validate/3）只在押金相关字段被改动时生效；
      # 规则挂载 / 传播路径在 before_action force 这些字段、看不见域校验（挂载
      # 路径的 registration_deadline 由 RuleInheritance.ensure_rule_deposit_invariant/1
      # 自理，ends_at 无守卫）——三条 CHECK 是这两条路径与未知裸 SQL 的唯一
      # 无条件兜底，经 handle_write_error/2 按约束名映射回同源 code。
      # 判据与域校验 cond / RuleInheritance 合并判据同语义（`deposit_enabled` 是
      # NOT NULL DEFAULT false，无 NULL 分支；若将来放开可空，CHECK 对 NULL 求值
      # 为 NULL = 放行，属预期）。
      # 迁移侧一律 NOT VALID 上线：不扫描存量（生产 0 违规 / dev 2 行脏行），
      # 新写入与存量行 UPDATE 立即受约束；存量回填 + VALIDATE 见 issue #634。
      # 三条判据两两可同时违反（如截止与 ends_at 俱空）——Postgres 只报其中一条，
      # 但三条各自映射的 code 都语义正确且可操作，不做 #597 式「不相交」细化。
      check_constraint(
        [:deposit_enabled, :registration_deadline],
        "events_deposit_requires_registration_deadline",
        check: "NOT (deposit_enabled AND registration_deadline IS NULL)",
        message:
          "registration_deadline is required when deposit is enabled (self-cancel cutoff anchor)"
      )

      check_constraint([:deposit_enabled, :ends_at], "events_deposit_requires_ends_at",
        check: "NOT (deposit_enabled AND ends_at IS NULL)",
        message: "ends_at is required when deposit is enabled (settlement anchor)"
      )

      check_constraint(
        [:deposit_enabled, :deposit_amount_cents],
        "events_deposit_requires_positive_amount",
        check:
          "NOT (deposit_enabled AND (deposit_amount_cents IS NULL OR deposit_amount_cents <= 0))",
        message: "a positive deposit_amount_cents is required when deposit is enabled"
      )
    end
  end

  policies do
    # 读取：成员可读非 draft；Owner/Admin 与平台管理员可读全部；
    # 匿名仅可读 open + visibility=public（公开发现面，D2 白名单由 field_policies 收窄）。
    policy action_type(:read) do
      authorize_if(Cgc2046.Offering.ActorReadsOffering)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(status == :open and visibility == :public))
      authorize_if({Cgc2046.Events.ReadsArchivedInitiativeEvent, []})
    end

    # 写操作：Owner/Admin（多角色并集）
    policy action_type([:create, :update]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    # 删除（#676，ADR-0015）：收窄面——Workspace Owner ∪ 平台管理员（同 Course
    # :destroy 口径；admin 不放行，理由 = 删除不可逆、无回收站）。MCP 面
    # member-only 门不含 platform_admin 豁免（S2 成文契约）。
    policy action_type(:destroy) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwner)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # D2 公开字段白名单（denylist 式，Ash field_policy 为 AND 语义：:* 恒放行，
  # 敏感字段另立 member-or-admin policy 收窄）。非白名单 = workspace_id /
  # curriculum_enabled / curriculum_requirements / workflow_run_id / capacity /
  # confirmed_count / detached_rule_provenance，匿名被筛除。
  #
  # detached_rule_provenance 是治理细节（值「被平台强制写入」这层来源信息，
  # 不是值本身）：公开宿主页（getEventBySlug 匿名读）不得暴露，与 #596
  # RulePreview「治理读面与公开面严格分开」同纪律。字段本身仍在 SDL（Event
  # 类型与 capacity 同款），匿名读恒 null。
  field_policies do
    field_policy :* do
      authorize_if(always())
    end

    field_policy [
      :workspace_id,
      :curriculum_enabled,
      :curriculum_requirements,
      :workflow_run_id,
      :capacity,
      :confirmed_count,
      :detached_rule_provenance
    ] do
      authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:workspace]})
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  graphql do
    type(:event)

    queries do
      list(:list_events, :list_events, description: "工作台的活动列表（#40 展示页）")
      read_one(:get_event, :get_by_id, description: "按 id 获取活动（#40）")
      read_one(:get_event_by_slug, :get_by_slug, description: "按 slug 获取（E-5 公开宿主页）")
    end

    mutations do
      create(:create_event, :create)
      update(:update_event, :update)
      update(:launch_event, :launch)
      update(:close_event, :close)
      update(:cancel_event, :cancel)

      # draft-only 删除（#676，ADR-0015）：授权面 = Owner ∪ 平台管理员（见 policies）。
      destroy(:delete_event, :delete)
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
