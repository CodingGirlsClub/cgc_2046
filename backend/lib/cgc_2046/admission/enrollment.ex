defmodule Cgc2046.Admission.Enrollment do
  @moduledoc """
  Event/Course 报名资源。

  核心并发不变量由数据库承担：名额账本行（CapacityLedger，`occupancy`）通过
  条件 UPDATE 占位（ADR-0009 PR⑤ U6，原 events/courses 计数列写点收编），
  InviteBatch 配额通过 `remaining_quota > 0` 条件 UPDATE 扣减，报名本身
  由两个部分唯一索引防重复。所有写都位于 Ash action 事务内，后续步骤失败会回滚
  已执行的计数更新。

  ## learning 锚定（唯一真源，架构深化 E；plan 2026-08-17-004）

  「learning run 锚定到哪条 Enrollment」的唯一读取面 = `anchor/1`（+ 双键提取
  `anchored_id/1`）。三消费方（Workflows→Admission 依赖方向）：
  `StepAuthorization.enrolled_learner?` / `LearningInstantiator` /
  `LearningProgressWorker`，各私有拷贝已收编于此。双键超集语义：string 键优先、
  atom 键兜底——可达输入全为 string 键（input_snapshot 经 JSONB 持久化；唯一
  写入方 LI 以 string 键构造 input），atom 分支仅激活于不可达的 in-memory 输入
  （安全方向，fail-closed 不放松）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Admission

  require Ash.Query
  require Logger

  alias Cgc2046.Admission.CapacityLedger
  alias Cgc2046.ApprovalClaim
  alias Cgc2046.Integrations.Wechat.Client

  # reason 内容安全平台判定白名单（替代 String.to_atom，杜绝未知字符串造原子）
  @content_check_platforms %{"wechat" => :wechat, "tt" => :tt, "xhs" => :xhs}

  @submitted_signal "enrollment.submitted"
  # #510 年龄门槛条款版本（单源）：min_age 非空的目标活动报名须显式确认，
  # 确认事实（age_confirmed_at）与当时条款版本（terms_version）同事务留痕。
  # 版本随代码部署演进——改条款语义时更新本值，存量留痕不回写。
  @terms_version "2026-09-participation"
  # review A1 容量上限：单事务批量免缴的待付笔数上限（定级依据见
  # waive_pending_for_offering moduledoc「容量契约」）
  @batch_waive_limit 200
  @approved_signal "enrollment.approved"
  @rejected_signal "enrollment.rejected"
  @completed_signal "enrollment.completed"

  # 目标 enrollment_policy 白名单（替代 String.to_existing_atom，杜绝未知字符串
  # 造原子 / 静默 raise；prepare_create/confirm 阶段解析后存入 changeset context）
  @enrollment_policy_atoms %{
    "open" => :open,
    "request" => :request,
    "invite_only" => :invite_only
  }

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false
    )

    attribute(:event_id, :uuid, public?: true, writable?: true)
    attribute(:course_id, :uuid, public?: true, writable?: true)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: true
    )

    attribute(:workflow_run_id, :uuid, public?: true, writable?: true)
    attribute(:invite_batch_id, :uuid, public?: true, writable?: false)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      writable?: false,
      constraints: [
        one_of: [:pending, :payment_pending, :confirmed, :rejected, :expired, :cancelled]
      ]
    )

    attribute(:submission_payload, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      writable?: true
    )

    attribute(:capacity_seq, :integer, public?: true, writable?: false)
    attribute(:approved_by, :uuid, public?: true, writable?: false)
    attribute(:approved_at, :utc_datetime, public?: true, writable?: false)
    attribute(:rejection_reason, :string, public?: true, writable?: false)
    attribute(:approval_deadline, :utc_datetime, public?: true, writable?: true)
    attribute(:expired_at, :utc_datetime, public?: true, writable?: false)
    attribute(:age_confirmed_at, :utc_datetime, public?: true)
    attribute(:terms_version, :string, public?: true)

    attribute(:cancelled_at, :utc_datetime, public?: true, writable?: false)

    # KTD5：Event 报名在 create 时生成同场唯一的 6 位核销码（course 报名为空）。
    # 明文存储——主理人按码查报名、参与者需反复回显，泄露只能让他人拿回自己
    # 的押金、无资金自利面。出示/核销按 confirmed 门控（graphql 字段级 resolve）。
    # filterable?: false——码不作查询面：否则可被当存在性预言机逐位试探
    # （6 位空间），绕过字段级出示门控（SecurityRev F1）。
    attribute(:check_in_code, :string,
      public?: true,
      writable?: false,
      filterable?: false,
      constraints: [match: ~r/^\d{6}$/]
    )

    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  calculations do
    calculate(:target_title, :string,
      public?: true,
      load: [:submission_payload, :workspace_id, :event_id, :course_id],
      calculation: fn enrollments, _opts ->
        fallback_rows =
          Enum.reject(enrollments, &is_binary(snapshot_target_title(&1)))

        titles =
          fallback_rows
          |> grouped_ids_by_kind()
          |> Enum.reduce(%{}, fn {workspace_id, ids_by_kind}, acc ->
            Map.merge(acc, Cgc2046.Offering.fetch_titles_by_ids(ids_by_kind, workspace_id))
          end)

        Enum.map(enrollments, fn enrollment ->
          snapshot_target_title(enrollment) ||
            target_title_from_offerings(enrollment, titles)
        end)
      end
    )

    # 日程化旅程 P2a：starts_at/venue 两公开字段共用本私有计算的一次批量
    # schedule fetch（load 依赖去重，startsAt+venue 同选不重复查询）。
    calculate(:target_schedule, :map,
      load: [:workspace_id, :event_id, :course_id],
      calculation: fn enrollments, _opts ->
        schedules =
          enrollments
          |> grouped_ids_by_kind()
          |> Enum.reduce(%{}, fn {workspace_id, ids_by_kind}, acc ->
            Map.merge(acc, Cgc2046.Offering.fetch_schedule_by_ids(ids_by_kind, workspace_id))
          end)

        Enum.map(enrollments, fn enrollment ->
          Map.get(schedules, enrollment.event_id || enrollment.course_id)
        end)
      end
    )

    calculate(:starts_at, :utc_datetime,
      public?: true,
      load: [:target_schedule],
      calculation: fn enrollments, _opts ->
        Enum.map(enrollments, fn enrollment ->
          case enrollment.target_schedule do
            %{starts_at: starts_at} -> starts_at
            _ -> nil
          end
        end)
      end
    )

    # U2：目标报名截止时间（参与者卡明示自助取消时点；同 starts_at 先例——
    # 从 target_schedule 批量取，不额外查 Offering）
    calculate(:registration_deadline, :utc_datetime,
      public?: true,
      load: [:target_schedule],
      calculation: fn enrollments, _opts ->
        Enum.map(enrollments, fn enrollment ->
          case enrollment.target_schedule do
            %{registration_deadline: deadline} -> deadline
            _ -> nil
          end
        end)
      end
    )

    # U3：目标缴费模式（free/pricing/deposit），码卡与取消规则的模式感知文案用。
    # 从 target_schedule 批量取（schedule_for 已带 deposit_enabled/pricing_enabled），
    # 三态判定单源 = Offering.payment_mode/1（押金优先；供给物不可得 → :free，与
    # 旧分支的兜底逐字一致）。
    calculate(:payment_mode, :string,
      public?: true,
      load: [:target_schedule],
      calculation: fn enrollments, _opts ->
        Enum.map(enrollments, fn enrollment ->
          enrollment.target_schedule
          |> Cgc2046.Offering.payment_mode()
          |> to_string()
        end)
      end
    )

    calculate(:venue, :string,
      public?: true,
      load: [:target_schedule],
      calculation: fn enrollments, _opts ->
        Enum.map(enrollments, fn enrollment ->
          case enrollment.target_schedule do
            %{venue: venue} -> venue
            _ -> nil
          end
        end)
      end
    )
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)
    belongs_to(:course, Cgc2046.Courses.Course, define_attribute?: false)
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun, define_attribute?: false)
    belongs_to(:invite_batch, Cgc2046.Admission.InviteBatch, define_attribute?: false)

    belongs_to(:approver, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :approved_by
    )
  end

  identities do
    identity :unique_event_user, [:event_id, :user_id] do
      where(expr(not is_nil(event_id) and status in [:pending, :payment_pending, :confirmed]))
    end

    identity :unique_course_user, [:course_id, :user_id] do
      where(expr(not is_nil(course_id) and status in [:pending, :payment_pending, :confirmed]))
    end

    # KTD5：同场核销码唯一（course 报名码为 NULL 不进索引——标准 SQL 语义下
    # NULL 不参与唯一约束，nils_distinct 默认 true 保持该语义）。
    identity :unique_check_in_code, [:event_id, :check_in_code] do
      where(expr(not is_nil(check_in_code)))
    end
  end

  # KTD5 出示门控（graphql_schema.check_in_code_visible?/2）要读 user_id 与
  # status，而 GraphQL 的字段选择（AshGraphql select_fields）只保留客户端请求
  # 的属性——不补选时，客户端没同时请求这两个字段的查询/变更结果会把本人
  # confirmed 报名误判为不可见（字段级 resolve 的隐性依赖，U4 回归用例：
  # `results { id status checkInCode }`）。资源级补齐：读 action 与
  # create/update/destroy 全覆盖；内部调用不设 select，语义不变。
  @check_in_code_gate_fields [:user_id, :status]

  preparations do
    prepare(fn query, _opts -> Ash.Query.ensure_selected(query, @check_in_code_gate_fields) end)
  end

  changes do
    change(fn changeset, _context ->
      Ash.Changeset.ensure_selected(changeset, @check_in_code_gate_fields)
    end)
  end

  actions do
    defaults([:read])

    # #411：keyset 分页要求稳定唯一序，而 UUID v4 主键时间无序——
    # 无显式 sort 时列表顺序契约上无保证（拒绝/重报多条乱序平铺真机回归）。
    # graphql 的 enrollments 列表改绑本 action（对齐 order.ex 先例，
    # inserted_at desc + id 兜底：同秒平票时 id 作 tiebreaker 保 keyset 序唯一）；
    # 默认 :read 保留 defaults 形态——显式重定义同名 action 会丢 graphql
    # list 的分页形态（KeysetPageOfEnrollment 退化为裸数组）。
    read :list_enrollments do
      description("报名列表（graphql enrollments；按插入时间倒序）")
      prepare(build(sort: [inserted_at: :desc, id: :asc]))
      pagination(keyset?: true, default_limit: 250)
    end

    read :my_enrollments do
      description("当前用户跨工作台的报名记录")
      filter(expr(user_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc, id: :asc]))
      pagination(keyset?: true, default_limit: 250)
    end

    create :create_enrollment do
      description("创建报名；open/invite_only 立即占位，request 等待审批")

      accept([
        :event_id,
        :course_id,
        :user_id,
        :workflow_run_id,
        :submission_payload,
        :approval_deadline
      ])

      argument(:invite_code, :string, allow_nil?: true)

      # KTD9：收费目标必填（put_tier_selection 校验并存入 submission_payload）
      argument(:tier_id, :string,
        allow_nil?: true,
        description: "价格档位 ID（收费活动报名时必填）"
      )

      # #510 年龄门槛：目标活动 min_age 非空时必须传 true（门控在
      # prepare_create 的 put_age_confirmation，权威在后端 action——web /
      # 小程序 / MCP 三入口同一扇门，UI 只是引导）
      argument(:age_confirmed, :boolean,
        allow_nil?: true,
        description: "确认已满目标活动要求的最低年龄（min_age 非空的活动必传 true）"
      )

      # 唯一约束（unique_event_user / unique_course_user）冲突转
      # BusinessError（code enrollment_duplicate_active）——error_handler 在
      # changeset 错误入列时介入（含 ash_postgres DB 层约束错误，见
      # membership_context.unique_membership_conflict?/1 同款判法）。
      error_handler({__MODULE__, :handle_create_error, []})

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)

      # 信号经 SignalEmitter 事务内 outbox 入队（plan 2026-08-14-003 Q6）：
      # 任何策略都发 submitted；open/invite_only 自动确认（confirmed）时再发
      # completed（KTD1/R3），两个 after_action 按声明顺序入队。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @submitted_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @completed_signal,
         payload: &__MODULE__.signal_payload/2,
         skip_unless: &__MODULE__.confirmed?/2}
      )
    end

    update :confirm_enrollment do
      description("Owner/Admin 确认 pending 报名并原子占用名额")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_confirm/1)
      end)

      # confirm 审批通过：先发 approved，再发 completed（生命周期终态）——
      # 失败路径（CAS 拒绝）不到 after_action，不产生孤儿 job。收费目标审批后
      # 落 payment_pending 而非 confirmed，completed 不发（KTD6-6：真正 confirmed
      # 才发，支付落账/免缴时补发）。
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @approved_signal, payload: &__MODULE__.approval_payload/2}
      )

      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @completed_signal,
         payload: &__MODULE__.signal_payload/2,
         skip_unless: &__MODULE__.confirmed?/2}
      )
    end

    update :reject_enrollment do
      description("Owner/Admin 拒绝 pending 报名")
      require_atomic?(false)
      accept([])
      argument(:rejection_reason, :string, allow_nil?: true)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_reject/1)
      end)

      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @rejected_signal, payload: &__MODULE__.approval_payload/2}
      )
    end

    update :expire do
      description("内部扫描把过期 pending 报名转 expired")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_expire/1)
      end)
    end

    update :cancel do
      description("报名人取消报名；confirmed/payment_pending 报名释放名额")
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_cancel/1)
      end)

      # 退款窗口内的自助取消把已付单（押金/定价）送入既有退款队列；窗口外的
      # 取消只释放名额（押金单锚报名截止 #587、定价单锚活动开始 #543）。该
      # after_action 与报名状态变更处于同一 Ash 事务，避免留下已取消但没有
      # 退款任务的崩溃窗口。
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn cs, enrollment ->
          enqueue_self_cancel_refunds(cs, enrollment)
        end)
      end)
    end

    update :waive_payment do
      description("Owner/Admin/平台管理员免缴：payment_pending → confirmed（个案免费唯一入口，R18）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_waive/1)
      end)

      # 免缴即真正 confirmed：补发 completed（支付落账路径在回调 worker 同款补发）
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @completed_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :waive_payment,
         target_type: :enrollment,
         metadata: &__MODULE__.waive_log_metadata/2}
      )
    end

    # 落账 worker 驱动（U7，KTD12）：支付回调落账后 payment_pending → confirmed。
    # CAS 失败分支（免缴先落/已过期取消）由 worker 按「收款但无对应占位 → 退款」
    # 不变量处理，不在本 action 内。
    update :settle_paid do
      description("支付落账：payment_pending → confirmed（内部，落账 worker 调用）")

      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_settle_paid/1)
      end)

      # 真正 confirmed 才发 completed（KTD6-6；与免缴路径同款补发）
      change(
        {Cgc2046.Workflows.SignalEmitter,
         type: @completed_signal, payload: &__MODULE__.signal_payload/2}
      )
    end
  end

  postgres do
    table("enrollments")
    repo(Cgc2046.Repo)

    identity_wheres_to_sql(
      unique_event_user:
        "event_id IS NOT NULL AND status IN ('pending', 'payment_pending', 'confirmed')",
      unique_course_user:
        "course_id IS NOT NULL AND status IN ('pending', 'payment_pending', 'confirmed')",
      unique_check_in_code: "check_in_code IS NOT NULL"
    )
  end

  policies do
    policy action(:create_enrollment) do
      forbid_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action([:confirm_enrollment, :reject_enrollment]) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    policy action(:waive_payment) do
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action(:cancel) do
      forbid_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:my_enrollments) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  graphql do
    generate_object?(false)
    type(:enrollment)

    sortable_fields([
      :id,
      :workspace_id,
      :event_id,
      :course_id,
      :user_id,
      :workflow_run_id,
      :invite_batch_id,
      :status,
      :submission_payload,
      :capacity_seq,
      :approved_by,
      :approved_at,
      :rejection_reason,
      :approval_deadline,
      :expired_at,
      :cancelled_at,
      :inserted_at
    ])

    queries do
      list(:enrollments, :list_enrollments)
      list(:my_enrollments, :my_enrollments)
    end

    mutations do
      create(:create_enrollment, :create_enrollment)
      update(:confirm_enrollment, :confirm_enrollment)
      update(:reject_enrollment, :reject_enrollment)
      update(:cancel_enrollment, :cancel)
      # waive_payment 的 web 面入口改为手写两段确认 mutation
      # （graphql_schema.ex + Cgc2046Web.PaymentConfirmation，复用 Mcp.PendingOperation）
    end
  end

  # ── learning 锚定（架构深化 E；plan 2026-08-17-004 D1）──────────────────

  @doc """
  learning run 锚定 Enrollment 的唯一读取真源：从 `map | binary` 提取锚点并
  读取 Enrollment。

  - 入参 `map`：`run.input_snapshot` / 信号 payload——经 `anchored_id/1` 双键
    提取（string 键优先）；`binary`：enrollment_id 直通；`nil`：视为无锚
    （防御 `input_snapshot` 可空，fail-closed 不放松）。
  - 无锚 → `{:error, :no_enrollment_anchor}`
  - 有锚但读取失败/不存在 → `{:error, :enrollment_read_failed}`（避开 payments
    域同名 `:enrollment_not_found`，D3）
  - 成功 → `{:ok, %Enrollment{}}`

  三消费方坍缩语义各自保持（SA fail-closed→false / LPW→nil·:skipped /
  LI→warning+:ok）。Enrollment 是 `global?(true)` 租户资源，PK 全局唯一，
  可不带 tenant 读。
  """
  @spec anchor(map() | binary() | nil) ::
          {:ok, Enrollment.t()} | {:error, :no_enrollment_anchor | :enrollment_read_failed}
  def anchor(input) do
    with {:ok, enrollment_id} <- anchored_id(input) do
      case Ash.get(__MODULE__, enrollment_id, authorize?: false) do
        {:ok, %__MODULE__{} = enrollment} -> {:ok, enrollment}
        {:ok, nil} -> {:error, :enrollment_read_failed}
        {:error, _} -> {:error, :enrollment_read_failed}
      end
    end
  end

  @doc """
  从 `map | binary | nil` 提取 learning run 锚定 enrollment_id（双键超集：
  string 键优先，`Map.get(m, "enrollment_id") || Map.get(m, :enrollment_id)`；
  binary 直通；nil 无锚）。

  可达输入全为 string 键（input_snapshot 经 JSONB 持久化；唯一写入方 LI 以
  string 键构造 input）——atom 键分支仅激活于不可达的 in-memory 输入，属安全
  方向（fail-closed 不放松）。供 `instance_key`/`input_enrollment_id` 等复用。
  """
  @spec anchored_id(map() | binary() | nil) ::
          {:ok, String.t()} | {:error, :no_enrollment_anchor}
  def anchored_id(input) when is_binary(input), do: {:ok, input}

  def anchored_id(nil), do: {:error, :no_enrollment_anchor}

  def anchored_id(input) when is_map(input) do
    case Map.get(input, "enrollment_id") || Map.get(input, :enrollment_id) do
      enrollment_id when is_binary(enrollment_id) -> {:ok, enrollment_id}
      _ -> {:error, :no_enrollment_anchor}
    end
  end

  # ── 活跃报名共享读取面（#355 P1-3；原 MCP LearnerJourney 收编）──────────

  @active_statuses [:pending, :payment_pending, :confirmed]

  @doc """
  活跃状态集（pending/payment_pending/confirmed，唯一索引 unique_event_user /
  unique_course_user 的占位状态集，identities 同款口径）：每个 (actor, offering)
  在活跃集内至多一条。
  """
  def active_statuses, do: @active_statuses

  @doc """
  actor 在目标 workspace 内、目标 offering 上的活跃报名（无 → nil）。带 actor
  走 read policy（`user_id == ^actor(:id)` 本人可读），actor 锚定无越权面；
  读取失败按无报名降级（发现/详情面的附挂信息不阻断主读）。

  workspace 过滤（#349 B）：幂等重放回读按 (actor, kind, offering, workspace)
  四元组钉死；offering UUID 全局唯一下为防御深度，fail-closed。
  """
  @spec active_enrollment(term(), :event | :course, String.t(), String.t()) ::
          __MODULE__.t() | nil
  def active_enrollment(actor, kind, offering_id, workspace_id) do
    {event_ids, course_ids} =
      if kind == :event, do: {[offering_id], []}, else: {[], [offering_id]}

    actor
    |> active_enrollments_by_offering(event_ids, course_ids, workspace_id)
    |> Map.get({kind, offering_id})
  end

  @doc """
  批量取 actor 在给定 offering id 集上的活跃报名：
  `%{(:event | :course, offering_id) => %Enrollment{}}`（消 N+1）。
  """
  @spec active_enrollments_by_offering(term(), [String.t()], [String.t()], String.t() | nil) ::
          %{{:event | :course, String.t()} => __MODULE__.t()}
  def active_enrollments_by_offering(actor, event_ids, course_ids, workspace_id \\ nil) do
    query =
      __MODULE__
      |> Ash.Query.filter(
        user_id == ^actor.id and status in ^@active_statuses and
          (event_id in ^event_ids or course_id in ^course_ids)
      )

    query =
      if workspace_id,
        do: Ash.Query.filter(query, workspace_id == ^workspace_id),
        else: query

    query
    |> Ash.read(actor: actor)
    |> case do
      {:ok, enrollments} ->
        Map.new(enrollments, fn enrollment ->
          {offering_key(enrollment), enrollment}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp offering_key(%{event_id: event_id}) when is_binary(event_id), do: {:event, event_id}
  defp offering_key(%{course_id: course_id}) when is_binary(course_id), do: {:course, course_id}

  defp snapshot_target_title(%{submission_payload: payload}) when is_map(payload) do
    case Map.get(payload, "targetTitle") || Map.get(payload, :targetTitle) do
      title when is_binary(title) and title != "" -> title
      _ -> nil
    end
  end

  defp snapshot_target_title(_enrollment), do: nil

  defp target_title_from_offerings(%{event_id: id}, titles) when is_binary(id),
    do: Map.get(titles, id, "报名项目")

  defp target_title_from_offerings(%{course_id: id}, titles) when is_binary(id),
    do: Map.get(titles, id, "报名项目")

  defp target_title_from_offerings(_enrollment, _titles), do: "报名项目"

  # 批量计算共用：按 workspace 分组提取 event/course 双键 id（空组剔除），
  # 供 Cgc2046.Offering 的 fetch_*_by_ids 保持 per-kind per-tenant 批量形状。
  defp grouped_ids_by_kind(enrollments) do
    enrollments
    |> Enum.group_by(& &1.workspace_id)
    |> Map.new(fn {workspace_id, rows} ->
      ids_by_kind =
        %{
          event: rows |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          course: rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        }
        |> Enum.reject(fn {_kind, ids} -> ids == [] end)
        |> Map.new()

      {workspace_id, ids_by_kind}
    end)
  end

  defp prepare_create(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    course_id = Ash.Changeset.get_attribute(changeset, :course_id)
    actor = changeset.context[:private][:actor]

    # 内容检查在 with 链首位（advisor09 F2）：msgSecCheck 外呼在
    # eligible_target 的 FOR SHARE 行锁获取之前执行，外呼不持锁。
    with :ok <- check_content(changeset, actor),
         {:ok, target_kind, target_id} <- exactly_one_target(event_id, course_id),
         :ok <- lock_qualification_target(event_id),
         {:ok, target} <- eligible_target(target_kind, target_id, actor),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, target.workspace_id),
         {:ok, attrs} <- prepare_policy(changeset, target_kind, target_id, target, tenant),
         {:ok, attrs} <- put_tier_selection(changeset, target, attrs),
         {:ok, attrs} <- put_deposit_selection(changeset, target, attrs),
         {:ok, attrs} <- put_age_confirmation(changeset, target, attrs),
         {:ok, attrs} <- put_check_in_code(attrs, target_kind, target_id) do
      changeset =
        Enum.reduce(attrs, changeset, fn {key, value}, cs ->
          Ash.Changeset.force_change_attribute(cs, key, value)
        end)

      # 目标 enrollment_policy 已由 eligible_target 加载（FOR SHARE），存入 context
      # 供 SignalEmitter payload fn 组装信号使用，避免提交后再查一次（#5）
      Ash.Changeset.put_context(changeset, :enrollment_policy, target.enrollment_policy)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # ── 内容安全（plan 2026-08-18-009 P2 + advisor09 F1-F3）────────────

  # submission_payload.reason 自由文本过内容安全检查。外呼在 with 链首位执行
  # （目标校验 / FOR SHARE 行锁获取之前，F2：外呼不持锁）。
  # - reason 缺失 → 放行（无可查内容）
  # - reason 存在但非 binary / 超 2500 字节 / 无效 UTF-8 → 拒绝（F3：检查产物 =
  #   落库产物，服务端前置校验，禁止静默截断）
  # - 违规（v2 result.suggest risky/review）→ {:error, :content_rejected}
  #   （fail-closed，内容不落库）
  # - infra 故障 → fail-open 放行（Client.content_check 内部已记 telemetry）
  # - 无 wechat identity（tt/xhs 单平台 / web 无 identity）→ pass-through 零外呼
  defp check_content(changeset, actor) do
    payload = Ash.Changeset.get_attribute(changeset, :submission_payload) || %{}
    reason = Map.get(payload, "reason") || Map.get(payload, :reason)

    cond do
      is_nil(reason) ->
        :ok

      not valid_reason?(reason) ->
        {:error, :content_rejected}

      true ->
        check_content_with_identity(actor, reason)
    end
  end

  defp valid_reason?(reason) when is_binary(reason),
    do: byte_size(reason) <= 2500 and String.valid?(reason)

  defp valid_reason?(_), do: false

  # msgSecCheck v2 需要 openid——从 user_identities 取 wechat uid
  # （order.ex:794 同款 SQL 先例；platform 判定查询复用，一次取 provider+uid）。
  # 有 wechat openid → wechat 检查；无 wechat identity（tt/xhs 单平台 / web 无
  # identity）/ 查询失败 → 放行（pass-through 语义，RISKS 记录——v2 无法在无
  # openid 下执行检查，与 tt/xhs 零外呼语义等价）。
  defp check_content_with_identity(actor, reason) do
    case actor_identities(actor) do
      {:ok, identities} ->
        case Map.get(identities, :wechat) do
          nil -> :ok
          openid -> run_wechat_check(reason, openid)
        end

      :error ->
        :ok
    end
  end

  defp run_wechat_check(reason, openid) do
    case Client.content_check(:wechat, reason, openid) do
      {:ok, _} -> :ok
      {:error, :content_rejected} -> {:error, :content_rejected}
    end
  end

  defp actor_identities(nil), do: {:ok, %{}}

  defp actor_identities(actor) do
    case Cgc2046.Repo.query(
           "SELECT DISTINCT provider, uid FROM user_identities WHERE user_id = $1",
           [Cgc2046.Repo.uuid!(actor.id)]
         ) do
      {:ok, %{rows: rows}} ->
        identities =
          rows
          |> Enum.map(fn [provider, uid] -> {@content_check_platforms[provider], uid} end)
          |> Enum.reject(fn {provider, _uid} -> is_nil(provider) end)
          |> Map.new()

        {:ok, identities}

      {:error, _} ->
        :error
    end
  end

  defp prepare_policy(changeset, _kind, _target_id, %{enrollment_policy: :request}, tenant) do
    deadline =
      Ash.Changeset.get_attribute(changeset, :approval_deadline) ||
        DateTime.add(DateTime.utc_now(), Cgc2046.ApprovalDeadline.default_timeout_days(), :day)

    {:ok, %{workspace_id: tenant, status: :pending, approval_deadline: deadline}}
  end

  # 收费目标：open/invite_only 占位后进 payment_pending（支付完成才 confirmed，
  # ADR-0007 占位→限时支付）；免费目标直接 confirmed（R4 现状不变）。
  # request 无论收费与否都先 pending（审批通过后 prepare_confirm 分叉）。
  defp prepare_policy(_changeset, kind, target_id, %{enrollment_policy: :open} = target, tenant) do
    with {:ok, sequence} <- reserve_capacity(kind, target_id) do
      {:ok, %{workspace_id: tenant, status: auto_confirm_status(target), capacity_seq: sequence}}
    end
  end

  defp prepare_policy(
         changeset,
         kind,
         target_id,
         %{enrollment_policy: :invite_only} = target,
         tenant
       ) do
    invite_code = Ash.Changeset.get_argument(changeset, :invite_code)

    with true <- (is_binary(invite_code) and invite_code != "") || {:error, :invite_code_required},
         {:ok, sequence} <- reserve_capacity(kind, target_id),
         {:ok, batch_id} <- consume_invite_quota(tenant, kind, target_id, invite_code) do
      {:ok,
       %{
         workspace_id: tenant,
         status: auto_confirm_status(target),
         capacity_seq: sequence,
         invite_batch_id: batch_id
       }}
    end
  end

  # 落点判定（KTD2）：定价开启或押金开启 → payment_pending（支付完成才 confirmed）；
  # 免费目标直接 confirmed。
  @doc """
  报名落点状态预测（KTD2）：缴费槽非免费 → `:payment_pending`（占位后限时支付，
  ADR-0007），免费 → `:confirmed`。

  create（open / invite_only）与审批通过（request）两条域路径共用本函数，MCP
  `get_enrollment_summary` 的 `would_create_status` 亦消费同一函数——三态判定只有
  一个实现点（`Offering.payment_mode/1`），展示面不再各自镜像。
  """
  @spec auto_confirm_status(map() | nil) :: :confirmed | :payment_pending
  def auto_confirm_status(target) do
    case Cgc2046.Offering.payment_mode(target) do
      :free -> :confirmed
      _ -> :payment_pending
    end
  end

  # 收费报名的档位选择（KTD9/R2）：tier_id 必填且当前可售，存 submission_payload
  # 供下单链快照（U5 resolve_tier）；免费目标忽略 tier_id（R4）。
  defp put_tier_selection(changeset, %{pricing_enabled: true, price_tiers: tiers}, attrs) do
    tier_id = Ash.Changeset.get_argument(changeset, :tier_id)

    with true <- (is_binary(tier_id) and tier_id != "") || {:error, :tier_id_required},
         {:ok, tier} <- Cgc2046.Offering.PriceTier.find(tiers, tier_id),
         true <-
           Cgc2046.Offering.PriceTier.available?(tier, DateTime.utc_now()) ||
             {:error, :tier_not_available} do
      {:ok,
       Map.put(
         attrs,
         :submission_payload,
         merge_payload_key(changeset, Map.get(attrs, :submission_payload), "tier_id", tier_id)
       )}
    end
  end

  defp put_tier_selection(_changeset, _target, attrs), do: {:ok, attrs}

  # 押金快照（U2/KTD1）：报名提交时物化目标押金金额，下单链以该快照为押金单
  # 金额源——Owner 事后改价不追溯存量 payment_pending 报名的承诺金额。定价目标
  # 忽略（金额源 = 下单时的档位解析）。金额非正（U3 校验前写入的历史脏行）不写
  # 快照：下单链 fail-closed 报 order_deposit_amount_missing，绝不以零金额调渠道。
  defp put_deposit_selection(
         changeset,
         %{deposit_enabled: true, deposit_amount_cents: amount},
         attrs
       )
       when is_integer(amount) and amount > 0 do
    {:ok,
     Map.put(
       attrs,
       :submission_payload,
       merge_payload_key(
         changeset,
         Map.get(attrs, :submission_payload),
         "deposit_amount_cents",
         amount
       )
     )}
  end

  defp put_deposit_selection(_changeset, _target, attrs), do: {:ok, attrs}

  # ── 年龄门槛（#510）──────────────────────────────────────────────────────
  # min_age 非空的目标活动（仅 events 有该列；course 恒 nil 走兜底）必须显式
  # 确认：argument :age_confirmed 非 true 即拒（fail-closed，MCP 不传同拒）。
  # 确认事实与条款版本同事务落列——审计可回答「何时同意的哪一版条款」。
  # 判据是 is_integer（min_age 有 CHECK min:1，无 0/负值分支）。
  defp put_age_confirmation(changeset, %{min_age: min_age}, attrs) when is_integer(min_age) do
    if Ash.Changeset.get_argument(changeset, :age_confirmed) == true do
      {:ok,
       attrs
       |> Map.put(:age_confirmed_at, DateTime.utc_now())
       |> Map.put(:terms_version, @terms_version)}
    else
      {:error, :age_confirmation_required}
    end
  end

  defp put_age_confirmation(_changeset, _target, attrs), do: {:ok, attrs}

  # submission_payload 累加写点（U2 起 tier_id 与 deposit_amount_cents 共存）：
  # 优先取链上已累积值、回落客户端提交原值，只覆盖本键——后写者不吞前写者，
  # 也不丢报名表单自带字段（reason / targetTitle）。
  defp merge_payload_key(changeset, payload, key, value) do
    (payload || Ash.Changeset.get_attribute(changeset, :submission_payload) || %{})
    |> Map.put(key, value)
  end

  # ── 核销码（U4/KTD5）────────────────────────────────────────────────────
  # Event 报名在 create 单写点生成同场唯一 6 位码（迁入 confirmed 的 5 个写点
  # 逐路径挂生成必漏——见计划 KTD5）；pending/payment_pending 行同占码，同场
  # 量级下可忽略。course 报名不生成。生成器共享自 Cgc2046.RandomCode（无偏
  # rejection sampling，保留前导零）；同场存在性查询避碰至多
  # @check_in_code_max_attempts 次，(event_id, check_in_code) 唯一索引兜底，
  # 兜底冲突由 handle_create_error 映射为可重试业务错误（unique_conflict?/1
  # 判据复用，错误文案不匹配）。
  @check_in_code_max_attempts 5
  # 兜底判据只用约束名：AshPostgres 的 constraints_to_errors 由约束名反查
  # identity，字段取身份首列（event_id，Ecto error_key），故 field 不能识别
  # 是哪条 identity 冲突；约束名 = `#{table}_#{identity.name}_index` 默认规则
  # （与 migration/快照一致）。
  @check_in_code_constraint "enrollments_unique_check_in_code_index"

  defp put_check_in_code(attrs, :event, event_id) do
    case allocate_check_in_code(event_id, @check_in_code_max_attempts) do
      {:ok, code} -> {:ok, Map.put(attrs, :check_in_code, code)}
      :error -> {:error, :check_in_code_exhausted}
    end
  end

  defp put_check_in_code(attrs, :course, _course_id), do: {:ok, attrs}

  # 测试注入的 deterministic 码必须同样参与避碰（否则耗尽用例退化为撞索引）。
  defp allocate_check_in_code(_event_id, 0), do: :error

  defp allocate_check_in_code(event_id, attempts_left) do
    code = Cgc2046.RandomCode.generate()

    if check_in_code_taken?(event_id, code) do
      allocate_check_in_code(event_id, attempts_left - 1)
    else
      {:ok, code}
    end
  end

  defp check_in_code_taken?(event_id, code) do
    %{rows: rows} =
      Cgc2046.Repo.query!(
        "SELECT 1 FROM enrollments WHERE event_id = $1 AND check_in_code = $2 LIMIT 1",
        [Cgc2046.Repo.uuid!(event_id), code]
      )

    rows != []
  end

  defp prepare_confirm(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]

    with {:ok, kind, target_id} <- target_from_record(changeset.data),
         :ok <- lock_qualification_target(changeset.data.event_id),
         {:ok, _} <- lock_for_order(changeset.data.id),
         {:ok, sequence} <- reserve_capacity(kind, target_id),
         {:ok, target_status, deposit_amount_cents} <- confirm_target_status(kind, target_id),
         {:ok, 1} <- claim_pending(changeset.data.id, target_status, actor.id, now, nil) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, target_status)
      |> Ash.Changeset.force_change_attribute(:capacity_seq, sequence)
      |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
      |> Ash.Changeset.force_change_attribute(:approved_at, now)
      |> put_deposit_snapshot(deposit_amount_cents)
      |> stash_target_policy(kind, target_id)
    else
      {:ok, 0} -> add_domain_error(changeset, :already_processed)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # 审批通过后的落点（KTD6-3 / KTD2）：定价或押金目标占位后进 payment_pending
  # （支付完成才 confirmed，由回调 worker 推进）；免费目标直接 confirmed（R4 现状
  # 不变）。押金两列仅 events 表有，courses 分支补 false（Order.load_target_row/2
  # 的 deposit_column 同款写法）。
  # 活值守卫（Fable 5 M1）：offering 真值行 status 必须为 open——账本缓存可能
  # 滞后于 cancel/close，仅信缓存会让「取消后批准」漏过批量退款扫描；真值读取
  # 在 reserve_capacity 之后执行:已同步的关闭/截止仍由账本 CAS 报
  # capacity_full_or_registration_closed(R14 钉测不动),未同步漂移才由本守卫报
  # target_not_open;失败路径随事务回滚,占位零泄漏。
  defp confirm_target_status(kind, target_id) do
    table = target_table(kind)

    case Cgc2046.Repo.query(
           "SELECT status, pricing_enabled#{deposit_columns(table)} FROM #{table} WHERE id = $1",
           [Cgc2046.Repo.uuid!(target_id)]
         ) do
      {:ok, %{rows: [["open", pricing_enabled, deposit_enabled, deposit_amount]]}} ->
        status =
          auto_confirm_status(%{
            pricing_enabled: pricing_enabled,
            deposit_enabled: deposit_enabled
          })

        # 押金快照（U2/KTD1）：审批通过落 payment_pending 与 create 路径共用同一
        # 金额源。定价目标不写（金额源 = 下单时的档位解析）。
        {:ok, status, if(deposit_enabled, do: deposit_amount, else: nil)}

      {:ok, %{rows: [[_status, _pricing_enabled, _deposit_enabled, _deposit_amount]]}} ->
        {:error, :target_not_open_or_registration_closed}

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # 审批通过路径的押金快照写入（U2/KTD1）：与 create 路径的 put_deposit_selection
  # 同源（同一 key），供下单链合成押金 tier。
  defp put_deposit_snapshot(changeset, nil), do: changeset

  defp put_deposit_snapshot(changeset, amount_cents) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :submission_payload,
      merge_payload_key(changeset, nil, "deposit_amount_cents", amount_cents)
    )
  end

  defp prepare_reject(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]
    reason = Ash.Changeset.get_argument(changeset, :rejection_reason)

    case claim_pending(changeset.data.id, :rejected, actor.id, now, reason) do
      {:ok, 1} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :rejected)
        |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
        |> Ash.Changeset.force_change_attribute(:approved_at, now)
        |> Ash.Changeset.force_change_attribute(:rejection_reason, reason)

      {:ok, 0} ->
        add_domain_error(changeset, :already_processed)

      {:error, reason} ->
        add_domain_error(changeset, reason)
    end
  end

  defp prepare_expire(changeset) do
    now = DateTime.utc_now()

    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：:passed 方向守卫
    # （approval_deadline IS NOT NULL AND < now）= ApprovalDeadline.overdue?/2 的
    # SQL 端口。0 行 = 已非 pending 或未过点，报 :not_expired_pending。
    case ApprovalClaim.claim(%{id: changeset.data.id},
           table: :enrollments,
           from: [:pending],
           set: [status: "expired", expired_at: {:arg, :now}],
           deadline: {:approval_deadline, :passed},
           now: now
         ) do
      {:ok, _returned} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :expired)
        |> Ash.Changeset.force_change_attribute(:expired_at, now)

      {:error, :not_claimed} ->
        add_domain_error(changeset, :not_expired_pending)

      {:error, {:database, _} = reason} ->
        add_domain_error(changeset, reason)
    end
  end

  defp prepare_cancel(changeset) do
    with {:ok, event} <- lock_cancel_target(changeset.data.event_id, changeset.data.course_id),
         now = DateTime.utc_now(),
         {:ok, capacity_target} <- claim_cancellable(changeset.data.id, now),
         :ok <- release_capacity(capacity_target),
         {:ok, _voided} <-
           Cgc2046.Payments.Order.void_pending_for_enrollment(
             changeset.data.id,
             "enrollment_cancelled"
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :cancelled)
      |> Ash.Changeset.force_change_attribute(:cancelled_at, now)
      # 退款资格双锚（#543）：押金单 = 报名截止前（#587）；定价单 = 活动开始前
      # （条款 5.2「活动开始前全额退」）。锚点在锁后读钟一次锁定，避免锁等待
      # 期间跨线。starts_at 缺失（畸形数据）→ false（fail-closed 不退）。
      |> Ash.Changeset.put_context(:self_cancel_before_deadline, before_deadline?(event, now))
      |> Ash.Changeset.put_context(
        :self_cancel_before_starts_at,
        before_starts_at?(event, now)
      )
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp enqueue_self_cancel_refunds(changeset, enrollment) do
    # #543：自助取消退款不再只认押金单——按订单口径分派锚点（押金单截止前 /
    # 定价单开始前全额退）。免费/免缴报名无活跃单，查询自然落空。
    orders =
      Cgc2046.Payments.Order
      |> Ash.Query.filter(
        enrollment_id == ^enrollment.id and
          status in [:paid, :refunding, :refund_failed]
      )
      |> Ash.read!(authorize?: false, tenant: enrollment.workspace_id)

    case orders do
      [order] ->
        if self_cancel_refund_eligible?(changeset, order) do
          enqueue_order_refund(order, enrollment)
        else
          {:ok, enrollment}
        end

      [] ->
        {:ok, enrollment}

      # 同一报名多条活跃单违反 unique_active_order 不变量（跨口径）：上抛回滚
      # 取消，不留「已取消但钱未退」的半态（after_action 的 {:error, _} 会提交）。
      _ ->
        raise "multiple active orders for enrollment #{enrollment.id}"
    end
  end

  defp enqueue_order_refund(order, enrollment) do
    # 入队必须 raise 型：Ash 3.33 的 after_action 返回 {:error, _} 会**提交**事务
    # （`transaction_rollback_on_error?` 未设），那样会留下「报名已取消、押金单
    # 仍 paid/refunding 且无退款 job」的静默吞钱（U6/KTD6 同款纪律：Attendance
    # 侧已按此改，自助取消侧此前漏改）。raise 用 BusinessError 是为了 #241 契约
    # 单源（code 经 AST 提取进 error_codes_contract.json）。
    case claim_refund_start(order, enrollment) do
      {:ok, refunding} ->
        Cgc2046.Payments.Workers.PaymentRefundWorker.new(%{"order_id" => refunding.id})
        |> Oban.insert!()

        {:ok, enrollment}

      {:error, :already_processed} ->
        # CAS 落空 = 并发路径已把订单推进：refunding/refunded 已有他路入队，良性；
        # 仍停在 paid 或已被 no-show 结算（forfeited）则与「截止前取消应全退」冲突，
        # 上抛回滚取消，绝不静默留钱。
        case reload_order_status(order) do
          status when status in [:refunding, :refunded] ->
            {:ok, enrollment}

          _other ->
            raise Cgc2046.Errors.BusinessError.exception(
                    message: domain_error_message(:deposit_settlement_race),
                    code: domain_error_code(:deposit_settlement_race)
                  )
        end
    end
  end

  defp claim_refund_start(order, enrollment) do
    case order.status do
      :paid ->
        order
        |> Ash.Changeset.for_update(:start_refund, %{})
        |> Ash.update(authorize?: false, tenant: enrollment.workspace_id)

      :refund_failed ->
        order
        |> Ash.Changeset.for_update(:retry_refund, %{})
        |> Ash.update(authorize?: false, tenant: enrollment.workspace_id)

      :refunding ->
        {:ok, order}
    end
  end

  defp reload_order_status(order) do
    case Cgc2046.Repo.query("SELECT status FROM payments_orders WHERE id = $1", [
           Cgc2046.Repo.uuid!(order.id)
         ]) do
      {:ok, %{rows: [[status]]}} -> String.to_existing_atom(status)
      _ -> :unknown
    end
  end

  # #543：退款资格按订单口径选锚——押金单 = 报名截止前（#587 既定语义）；
  # 定价单 = 活动开始前（条款 5.2）。锚点布尔在 prepare_cancel 锁后统一判定。
  defp self_cancel_refund_eligible?(changeset, order) do
    case order.order_kind do
      :deposit -> Map.get(changeset.context, :self_cancel_before_deadline) == true
      :enrollment -> Map.get(changeset.context, :self_cancel_before_starts_at) == true
    end
  end

  defp before_deadline?(%{registration_deadline: nil}, _now), do: true

  defp before_deadline?(%{registration_deadline: %NaiveDateTime{} = deadline}, now),
    do: DateTime.compare(now, DateTime.from_naive!(deadline, "Etc/UTC")) == :lt

  defp before_deadline?(%{registration_deadline: deadline}, now),
    do: DateTime.compare(now, deadline) == :lt

  # 定价单自助取消锚（#543）：活动开始前 = 可退。starts_at 缺失 → false
  # fail-closed（定价场 ⇒ starts_at 非空由 DB CHECK 兜底，此处只兜残差）。
  defp before_starts_at?(%{starts_at: nil}, _now), do: false

  defp before_starts_at?(%{starts_at: %NaiveDateTime{} = starts_at}, now),
    do: DateTime.compare(now, DateTime.from_naive!(starts_at, "Etc/UTC")) == :lt

  defp before_starts_at?(%{starts_at: starts_at}, now),
    do: DateTime.compare(now, starts_at) == :lt

  # All qualification-sensitive transitions acquire this lock before touching
  # Enrollment/ledger/order rows. Read the clock after a possible lock wait.
  defp lock_qualification_target(nil), do: :ok

  defp lock_qualification_target(event_id) do
    case Cgc2046.Repo.query(
           "SELECT status, registration_deadline, min_participants FROM events WHERE id = $1 FOR UPDATE",
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: [[_status, _deadline, nil]]}} ->
        :ok

      {:ok, %{rows: [[status, deadline, _minimum]]}} ->
        if status == "open" and
             before_deadline?(%{registration_deadline: deadline}, DateTime.utc_now()),
           do: :ok,
           else: {:error, :target_not_open_or_registration_closed}

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp lock_cancel_target(event_id, nil) when not is_nil(event_id) do
    case Cgc2046.Repo.query(
           "SELECT registration_deadline, starts_at FROM events WHERE id = $1 FOR UPDATE",
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: [[deadline, starts_at]]}} ->
        {:ok, %{registration_deadline: deadline, starts_at: starts_at}}

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # course 无报名截止概念（恒 nil），但定价单退款锚 = 开课时间（#543）——与
  # event 同构锁读 starts_at（锁行防并发改期跨线）。
  defp lock_cancel_target(nil, course_id) when not is_nil(course_id) do
    case Cgc2046.Repo.query(
           "SELECT starts_at FROM courses WHERE id = $1 FOR UPDATE",
           [Cgc2046.Repo.uuid!(course_id)]
         ) do
      {:ok, %{rows: [[starts_at]]}} ->
        {:ok, %{registration_deadline: nil, starts_at: starts_at}}

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  defp lock_cancel_target(nil, nil), do: {:error, :target_not_found}

  defp lock_cancel_target(_event_id, _course_id), do: {:error, :target_not_found}

  # 作废语义已收编至 Payments 端口 Order.void_pending_for_enrollment/2
  # （ADR-0009 Fable 5 MEDIUM-2）：R12/e2e #1——取消/免缴在离开占位态的同一
  # 事务内作废报名关联 pending 订单，脏窗口/AE2 兜底论证见该端口文档。

  # 支付落账（U7，KTD12）：CAS payment_pending → confirmed（免缴/过期/取消竞态
  # 由 num_rows=0 上抛给 worker 走自动退款分支）。
  defp prepare_settle_paid(changeset) do
    case lock_qualification_target(changeset.data.event_id) do
      :ok -> do_settle_paid(changeset)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  defp do_settle_paid(changeset) do
    sql = """
    UPDATE enrollments
    SET status = 'confirmed', updated_at = NOW()
    WHERE id = $1 AND status = 'payment_pending'
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(changeset.data.id)]) do
      {:ok, %{num_rows: 1}} ->
        Ash.Changeset.force_change_attribute(changeset, :status, :confirmed)

      {:ok, %{num_rows: 0}} ->
        add_domain_error(changeset, :already_processed)

      {:error, reason} ->
        add_domain_error(changeset, {:database, reason})
    end
  end

  # 免缴（R18）：CAS payment_pending → confirmed + 同事务作废 pending 订单
  # （e2e #1：免缴后订单仍 pending 会继续计入待收统计，且本地作废不关渠道
  # 单、QR 仍可被支付——迟到收款由落账 worker 的作废单自动退款分支兜底，
  # AE2 语义）。名额已在报名/审批占位时扣减，此处只做状态迁移；审计走
  # LogAdminAction。
  defp prepare_waive(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]

    with :ok <- lock_qualification_target(changeset.data.event_id),
         {:ok, 1} <- claim_waive(changeset.data.id, actor.id, now),
         {:ok, _voided} <-
           Cgc2046.Payments.Order.void_pending_for_enrollment(changeset.data.id, "waived") do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :confirmed)
      |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
      |> Ash.Changeset.force_change_attribute(:approved_at, now)
    else
      {:ok, 0} ->
        add_domain_error(changeset, :not_payment_pending)

      {:error, reason} ->
        add_domain_error(changeset, {:database, reason})
    end
  end

  @doc """
  R9/KTD4 关闭收费批量免费确认：offering 的 payment_pending 报名逐条复用
  免缴三元组（claim_waive CAS + Order.void_pending_for_enrollment + 免缴审计行）+ 补发
  completed 信号（与单笔 waive_payment action 同语义）。须在 Event/Course
  update 事务内（after_action）调用；任一笔失败上抛，调用方整体回滚。

  竞态：CAS num_rows=0（落账先到/报名已流转）跳过该笔——先落账者保持已付；
  迟到扣款由落账 worker 按免缴审计行判定自动原路退回（KTD4 正确性约束：
  审计行不可省）。无待付报名时 no-op；有待付但无 actor → {:error,
  :actor_required}（组织者发起的治理动作必须有操作者）。

  ## 容量契约（review A1 定级）

  单事务内逐条处理，事务时长随待付笔数线性增长（每笔 3 条 SQL + 信号入队）。
  上限 @batch_waive_limit（200 笔 ≈ 800 条语句，事务 < 2s，远低于连接池
  超时与锁等待阈值）；超限拒绝并提示组织者先处理部分待付（或走取消活动
  路径——取消信号经 worker 分批异步，无此约束）。超过上限的规模化场景
  需要改造成可恢复批次（chunks + after_transaction 批间提交），当前产品
  阶段（社区活动）不引入。
  """
  def waive_pending_for_offering(kind, id, actor, workspace_id)
      when kind in [:event, :course] do
    pending =
      kind
      |> pending_offering_scope(id)
      |> Ash.read!(authorize?: false, tenant: workspace_id)

    cond do
      pending == [] ->
        :ok

      length(pending) > @batch_waive_limit ->
        {:error, :batch_waive_limit_exceeded}

      is_nil(actor) ->
        {:error, :actor_required}

      true ->
        Enum.reduce_while(pending, :ok, fn enrollment, :ok ->
          case waive_for_pricing_disable(enrollment, actor, workspace_id) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  支付超时释放端口（ADR-0009 U5 / R20；KTD6 同事务）：`Order :expire` 在订单
  CAS 同事务内调用——报名 CAS payment_pending→expired（落 expired_at）+ 账本
  occupancy 释放一步完成（U6 收编）；任一步失败返回 {:error, _}，调用方整体回滚
  （含订单 CAS），扫描下拍重试。

  报名已流转（免缴 confirmed / 已取消）时 CAS num_rows=0 → :ok，无名额可释，
  订单过期照常，迟到收款由落账 worker 自动退款链兜底（KTD12 不变量）。
  """
  def release_for_payment_expiry(enrollment_id) do
    sql = """
    UPDATE enrollments
    SET status = 'expired', expired_at = NOW(), updated_at = NOW()
    WHERE id = $1 AND status = 'payment_pending'
    RETURNING event_id, course_id
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(enrollment_id)]) do
      {:ok, %{rows: [[event_id, nil]]}} when not is_nil(event_id) ->
        release_capacity({:event, Ecto.UUID.load!(event_id)})

      {:ok, %{rows: [[nil, course_id]]}} when not is_nil(course_id) ->
        release_capacity({:course, Ecto.UUID.load!(course_id)})

      {:ok, %{rows: []}} ->
        :ok

      {:ok, _unexpected} ->
        {:error, :enrollment_target_shape}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pending_offering_scope(:event, id) do
    Ash.Query.filter(__MODULE__, status == :payment_pending and event_id == ^id)
  end

  defp pending_offering_scope(:course, id) do
    Ash.Query.filter(__MODULE__, status == :payment_pending and course_id == ^id)
  end

  # 逐条免缴（三元组 + 信号）；CAS num_rows=0 = 竞态窗口先落账者，跳过。
  defp waive_for_pricing_disable(enrollment, actor, workspace_id) do
    now = DateTime.utc_now()

    with :ok <- lock_qualification_target(enrollment.event_id),
         {:ok, 1} <- claim_waive(enrollment.id, actor.id, now),
         {:ok, _voided} <-
           Cgc2046.Payments.Order.void_pending_for_enrollment(enrollment.id, "waived"),
         {:ok, _log} <-
           Cgc2046.Accounts.AdminActionLog.log(%{
             actor_id: actor.id,
             action: :waive_payment,
             target_type: :enrollment,
             target_id: enrollment.id,
             metadata: waive_log_metadata(nil, enrollment)
           }) do
      emit_completed(%{enrollment | status: :confirmed}, workspace_id)
      :ok
    else
      {:ok, 0} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # completed 信号补发（批量路径无 changeset，enrollment_policy 落 nil——
  # confirm 路径同款先例；幂等键由消费方 SignalIdempotency 去重）。payload
  # 基座复用 base_enrollment_payload/1（同模块单源；enrollment 为批量路径
  # 重构的 confirmed 内存记录）——emitter 键注入与 SignalEmitter 同款两行。
  defp emit_completed(enrollment, workspace_id) do
    payload =
      base_enrollment_payload(enrollment)
      |> Map.merge(%{
        "event_id" => enrollment.event_id,
        "course_id" => enrollment.course_id,
        "enrollment_policy" => nil
      })
      |> Map.put("idempotency_key", @completed_signal <> ":" <> enrollment.id)
      |> Map.put("workspace_id", enrollment.workspace_id)

    Cgc2046.Workflows.SignalPublishWorker.enqueue_in_transaction(
      @completed_signal,
      payload,
      workspace_id
    )
  end

  defp exactly_one_target(event_id, nil) when is_binary(event_id), do: {:ok, :event, event_id}
  defp exactly_one_target(nil, course_id) when is_binary(course_id), do: {:ok, :course, course_id}
  defp exactly_one_target(_, _), do: {:error, :exactly_one_target_required}

  defp target_from_record(%{event_id: event_id, course_id: nil}) when is_binary(event_id),
    do: {:ok, :event, event_id}

  defp target_from_record(%{event_id: nil, course_id: course_id}) when is_binary(course_id),
    do: {:ok, :course, course_id}

  defp target_from_record(_), do: {:error, :exactly_one_target_required}

  defp eligible_target(kind, id, actor) do
    table = target_table(kind)
    actor_id = if actor, do: Cgc2046.Repo.uuid!(actor.id), else: nil

    # G1（E-5 #50 安全洞修复）：公开报名只对 `open + visibility=public` 活动；
    # workspace-only 活动仅目标 workspace 成员可报（成员路径 D2，工作台详情页
    # 入口走同一 createEnrollment）。非成员/匿名对 workspace-only 报名 → 本函数
    # 返回 :target_not_open_or_registration_closed（not_found 语义，与匿名读一致，
    # 不泄露存在性）。行为变化：此前非成员可经 API 报名 workspace-only，属漏洞。
    # 押金两列（KTD2）：仅 events 表有，courses 分支补 false（Order.load_target_row/2
    # 的 deposit_column 同款写法）。
    # min_age 列（#510）：仅 events 表有，courses 补 NULL 保持列数一致（同
    # deposit_columns 形状）。
    sql = """
    SELECT workspace_id, enrollment_policy, pricing_enabled, price_tiers#{deposit_columns(table)}#{min_age_columns(table)}
    FROM #{table}
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > clock_timestamp())
      AND (
        visibility = 'public'
        OR EXISTS (
          SELECT 1 FROM workspace_memberships wm
          WHERE wm.workspace_id = #{table}.workspace_id
            AND wm.user_id = $2
        )
      )
    FOR SHARE
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(id), actor_id]) do
      {:ok,
       %{
         rows: [
           [
             workspace_id,
             policy,
             pricing_enabled,
             price_tiers,
             deposit_enabled,
             deposit_amount,
             min_age
           ]
         ]
       }} ->
        case Map.get(@enrollment_policy_atoms, policy) do
          nil ->
            {:error, {:unknown_enrollment_policy, policy}}

          enrollment_policy ->
            {:ok,
             %{
               workspace_id: Ecto.UUID.load!(workspace_id),
               enrollment_policy: enrollment_policy,
               pricing_enabled: pricing_enabled,
               price_tiers: price_tiers || [],
               deposit_enabled: deposit_enabled,
               deposit_amount_cents: deposit_amount,
               min_age: min_age
             }}
        end

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # confirm 路径的目标 enrollment_policy 单次查询（#5：事务内解析并存入 context，
  # 不再提交后再查）。失败只记日志、stash nil，不阻断确认动作本身。
  defp stash_target_policy(changeset, kind, target_id) do
    policy =
      case target_policy(kind, target_id) do
        {:ok, policy} ->
          policy

        {:error, reason} ->
          Logger.error(
            "failed to read enrollment_policy for #{kind} #{target_id}: #{inspect(reason)}"
          )

          nil
      end

    Ash.Changeset.put_context(changeset, :enrollment_policy, policy)
  end

  defp target_policy(kind, id) do
    table = target_table(kind)

    case Cgc2046.Repo.query("SELECT enrollment_policy FROM #{table} WHERE id = $1", [
           Cgc2046.Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[policy]]}} ->
        case Map.get(@enrollment_policy_atoms, policy) do
          nil -> {:error, {:unknown_policy, policy}}
          atom -> {:ok, atom}
        end

      {:ok, %{rows: []}} ->
        {:error, :target_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  # R14：占位 CAS 收编账本行（守卫三条件原样复刻；懒建 upsert 兜底在账本侧，
  # KTD5）。返回值 = 账本 occupancy（capacity_seq 语义随之改指账本计数）。
  defp reserve_capacity(kind, id), do: CapacityLedger.reserve(kind, id)

  defp consume_invite_quota(workspace_id, kind, target_id, invite_code) do
    target_column = if kind == :event, do: "event_id", else: "course_id"

    sql = """
    UPDATE invite_batches
    SET remaining_quota = remaining_quota - 1, updated_at = NOW()
    WHERE workspace_id = $1 AND #{target_column} = $2 AND invite_code = $3
      AND status = 'active' AND remaining_quota > 0
      AND (expires_at IS NULL OR expires_at > NOW())
    RETURNING id
    """

    case Cgc2046.Repo.query(sql, [
           Cgc2046.Repo.uuid!(workspace_id),
           Cgc2046.Repo.uuid!(target_id),
           invite_code
         ]) do
      {:ok, %{rows: [[id]]}} -> {:ok, Ecto.UUID.load!(id)}
      {:ok, %{rows: []}} -> {:error, :invite_quota_unavailable}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp claim_pending(id, status, actor_id, now, rejection_reason) do
    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：confirm/reject
    # 共用 pending 状态窗口条件 UPDATE；approval_deadline 守卫 = not_expired?/2 的
    # SQL 端口。返回 {:ok, count} / {:error, {:database, reason}}，错误映射由调用方
    # （prepare_confirm/prepare_reject）承担（D3）。
    case ApprovalClaim.claim(%{id: id},
           table: :enrollments,
           from: [:pending],
           set: [
             status: {:arg, :status},
             approved_by: {:arg, :actor_id},
             approved_at: {:arg, :now},
             rejection_reason: {:arg, :rejection_reason}
           ],
           deadline: {:approval_deadline, :future},
           status: to_string(status),
           actor_id: Cgc2046.Repo.uuid!(actor_id),
           now: now,
           rejection_reason: rejection_reason
         ) do
      {:ok, _returned} -> {:ok, 1}
      {:error, :not_claimed} -> {:ok, 0}
      {:error, {:database, _} = reason} -> {:error, reason}
    end
  end

  defp claim_waive(id, actor_id, now) do
    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：payment_pending →
    # confirmed 免缴 CAS。返回 {:ok, count} / {:error, {:database, reason}}，错误映射由
    # 调用方（prepare_waive）承担（D3）。
    case ApprovalClaim.claim(%{id: id},
           table: :enrollments,
           from: [:payment_pending],
           set: [
             status: "confirmed",
             approved_by: {:arg, :actor_id},
             approved_at: {:arg, :now},
             rejection_reason: nil
           ],
           actor_id: Cgc2046.Repo.uuid!(actor_id),
           now: now
         ) do
      {:ok, _returned} -> {:ok, 1}
      {:error, :not_claimed} -> {:ok, 0}
      {:error, {:database, _} = reason} -> {:error, reason}
    end
  end

  defp claim_cancellable(id, now) do
    # payment_pending 与 confirmed 同为已占位窗口——取消必须释放名额（KTD6-4）。
    # 原子抢占收编 Cgc2046.ApprovalClaim（plan 2026-08-17-001 D4）：多状态 IN +
    # RETURNING 回读 capacity_seq/event_id/course_id（0 行 → :not_claimed →
    # :already_processed；返回值的容量目标分派留调用方，D3）。
    case ApprovalClaim.claim(%{id: id},
           table: :enrollments,
           from: [:pending, :payment_pending, :confirmed],
           set: [status: "cancelled", cancelled_at: {:arg, :now}],
           returning: [:capacity_seq, :event_id, :course_id],
           now: now
         ) do
      {:ok, %{capacity_seq: nil, event_id: _event_id, course_id: _course_id}} ->
        {:ok, nil}

      {:ok, %{capacity_seq: _capacity_seq, event_id: event_id, course_id: nil}}
      when not is_nil(event_id) ->
        {:ok, {:event, Ecto.UUID.load!(event_id)}}

      {:ok, %{capacity_seq: _capacity_seq, event_id: nil, course_id: course_id}}
      when not is_nil(course_id) ->
        {:ok, {:course, Ecto.UUID.load!(course_id)}}

      {:ok, _unexpected} ->
        {:error, :capacity_counter_invalid}

      {:error, :not_claimed} ->
        {:error, :already_processed}

      {:error, {:database, _} = reason} ->
        {:error, reason}
    end
  end

  # R14：释放 CAS 收编账本行（occupancy > 0 守卫语义不变）
  defp release_capacity(capacity_target), do: CapacityLedger.release(capacity_target)

  # GraphQL 入口不注入 tenant（nil 时从目标派生）；显式传错 tenant 仍拒绝（防跨 workspace 越权）
  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  defp target_table(:event), do: "events"
  defp target_table(:course), do: "courses"

  # 押金两列（KTD2）：仅 events 表有；courses 补 false/NULL 保持 SELECT 列数一致。
  defp deposit_columns("events"), do: ", COALESCE(deposit_enabled, false), deposit_amount_cents"
  defp deposit_columns(_table), do: ", false, NULL"
  # 年龄一列（#510）：仅 events 表有；courses 补 NULL。
  defp min_age_columns("events"), do: ", min_age"
  defp min_age_columns(_table), do: ", NULL"

  # ── 错误构造（i18n Phase 0：BusinessError 携带稳定 code，前端按 code 查文案）──

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(
      changeset,
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(reason),
        code: domain_error_code(reason),
        fields: [:status]
      )
    )
  end

  # create_enrollment 唯一约束冲突转业务错误。并发重复 / 已有活跃报名 →
  # enrollment_duplicate_active；核销码同场撞唯一索引（避碰 5 次窗口外的并发
  # 兜底，KTD5）→ enrollment_check_in_code_exhausted（可重试业务错误，文案
  # 不镜像 duplicate_active）。判据 = 唯一冲突 + 约束名指向核销码索引，不匹配
  # 文案。非 unique 错误原样返回（error_handler 返回值即入列的错误）。
  def handle_create_error(_changeset, error) do
    cond do
      check_in_code_conflict?(error) ->
        Cgc2046.Errors.BusinessError.exception(
          message: domain_error_message(:check_in_code_exhausted),
          code: domain_error_code(:check_in_code_exhausted),
          fields: [:check_in_code]
        )

      Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) ->
        Cgc2046.Errors.BusinessError.exception(
          message: domain_error_message(:duplicate_active),
          code: domain_error_code(:duplicate_active)
        )

      true ->
        error
    end
  end

  defp check_in_code_conflict?(error) do
    Cgc2046.Errors.ConstraintConflict.unique_conflict?(error) and
      Cgc2046.Errors.ConstraintConflict.constraint_named?(error, @check_in_code_constraint)
  end

  defp domain_error_message(:exactly_one_target_required),
    do: "exactly one of event_id/course_id is required"

  defp domain_error_message(:target_not_open_or_registration_closed),
    do: "target is not open or registration deadline passed"

  defp domain_error_message(:target_tenant_mismatch), do: "target does not belong to tenant"
  defp domain_error_message(:capacity_full_or_registration_closed), do: "capacity is full"
  defp domain_error_message(:invite_code_required), do: "invite code is required"
  defp domain_error_message(:invite_quota_unavailable), do: "invite quota is unavailable"
  defp domain_error_message(:tier_id_required), do: "a price tier is required for paid enrollment"

  defp domain_error_message(:tier_not_available),
    do: "selected price tier is not available"

  defp domain_error_message(:age_confirmation_required),
    do: "age confirmation is required for this enrollment"

  defp domain_error_message(:already_processed), do: "enrollment has already been processed"

  defp domain_error_message(:duplicate_active),
    do: "an active enrollment already exists for this target"

  defp domain_error_message(:check_in_code_exhausted),
    do: "could not allocate a unique check-in code; please retry"

  # 通用文案，不含 reason 明文（红线：违规内容不进错误消息）
  defp domain_error_message(:content_rejected),
    do: "submission content was rejected by content safety check"

  defp domain_error_message({:unknown_enrollment_policy, _policy}),
    do: "target has an unknown enrollment policy"

  defp domain_error_message(:not_expired_pending),
    do: "enrollment is not an expired pending record"

  defp domain_error_message(:not_payment_pending),
    do: "enrollment is not awaiting payment"

  defp domain_error_message(:deposit_settlement_race),
    do: "the deposit order was settled by a concurrent path; enrollment cancel rolled back"

  defp domain_error_message(:capacity_counter_invalid), do: "capacity counter is invalid"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

  defp domain_error_code({:database, _reason}), do: "database_error"

  defp domain_error_code(:exactly_one_target_required),
    do: "enrollment_exactly_one_target_required"

  defp domain_error_code(:target_not_open_or_registration_closed),
    do: "enrollment_target_not_open_or_registration_closed"

  defp domain_error_code(:target_tenant_mismatch), do: "enrollment_target_tenant_mismatch"

  defp domain_error_code(:capacity_full_or_registration_closed),
    do: "enrollment_capacity_full_or_registration_closed"

  defp domain_error_code(:invite_code_required), do: "enrollment_invite_code_required"
  defp domain_error_code(:invite_quota_unavailable), do: "enrollment_invite_quota_unavailable"
  defp domain_error_code(:tier_id_required), do: "enrollment_tier_id_required"
  defp domain_error_code(:tier_not_available), do: "enrollment_tier_not_available"
  # 显式子句化（#241）：进契约工件，web/小程序按 code 配文案
  defp domain_error_code(:age_confirmation_required),
    do: "enrollment_age_confirmation_required"

  defp domain_error_code(:already_processed), do: "enrollment_already_processed"
  defp domain_error_code(:duplicate_active), do: "enrollment_duplicate_active"
  defp domain_error_code(:check_in_code_exhausted), do: "enrollment_check_in_code_exhausted"

  defp domain_error_code({:unknown_enrollment_policy, _policy}),
    do: "enrollment_unknown_enrollment_policy"

  defp domain_error_code(:not_expired_pending), do: "enrollment_not_expired_pending"
  defp domain_error_code(:not_payment_pending), do: "enrollment_not_payment_pending"
  defp domain_error_code(:deposit_settlement_race), do: "deposit_settlement_race"
  defp domain_error_code(:capacity_counter_invalid), do: "enrollment_capacity_counter_invalid"

  # 显式子句化（#241）：原走兜底动态拼接，不进契约工件但 miniprogram 已配文案
  defp domain_error_code(:content_rejected), do: "enrollment_content_rejected"

  defp domain_error_code(reason) when is_atom(reason),
    do: "enrollment_" <> Atom.to_string(reason)

  defp domain_error_code({kind, _}) when is_atom(kind),
    do: "enrollment_" <> Atom.to_string(kind)

  defp domain_error_code(_), do: "enrollment_unknown"

  # ── ⑨ 跨域行锁端口（ADR-0010 批次4 清偿）────────────────────────────────
  # Payments 下单链对 enrollments 的裸 SQL 直读收编为本端口（SQL 原样内迁，
  # 返回形状与 Payments.Order 旧内联实现逐键一致，行为零变化）。

  @doc """
  下单链路行锁读（review F5）：`SELECT … FOR UPDATE` 序列化下单与批量免缴
  竞态——**调用方须在事务内调用，行锁存活至其事务提交**；锁内重读的 status
  是裁决口径（免缴先提交则读 confirmed 拒单）。
  返回 `{:ok, %{id, workspace_id, user_id, status, event_id, course_id,
  submission_payload}}` / `{:error, :enrollment_not_found | :enrollment_required
  | {:database, term()}}`。
  """
  @spec lock_for_order(term()) ::
          {:ok, map()}
          | {:error, :enrollment_not_found | :enrollment_required | {:database, term()}}
  def lock_for_order(id) when is_binary(id) do
    sql = """
    SELECT id, workspace_id, user_id, status, event_id, course_id, submission_payload
    FROM enrollments WHERE id = $1 FOR UPDATE
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(id)]) do
      {:ok, %{rows: [[id, ws, user_id, status, event_id, course_id, payload]]}} ->
        {:ok,
         %{
           id: Ecto.UUID.load!(id),
           workspace_id: Ecto.UUID.load!(ws),
           user_id: Ecto.UUID.load!(user_id),
           status: lock_status_to_atom(status),
           event_id: event_id && Ecto.UUID.load!(event_id),
           course_id: course_id && Ecto.UUID.load!(course_id),
           submission_payload: payload || %{}
         }}

      {:ok, %{rows: []}} ->
        {:error, :enrollment_not_found}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
  end

  def lock_for_order(_id), do: {:error, :enrollment_required}

  @doc """
  下单租户解析读（U1 骨架从 enrollment 派生租户）：无锁直读 workspace_id。
  返回 `{:ok, workspace_id}` / `{:error, :enrollment_not_found |
  :enrollment_required | {:database, term()}}`。
  """
  @spec workspace_id_for_order(term()) ::
          {:ok, Ecto.UUID.t()}
          | {:error, :enrollment_not_found | :enrollment_required | {:database, term()}}
  def workspace_id_for_order(id) when is_binary(id) do
    case Cgc2046.Repo.query("SELECT workspace_id FROM enrollments WHERE id = $1", [
           Cgc2046.Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[workspace_id]]}} -> {:ok, Ecto.UUID.load!(workspace_id)}
      {:ok, %{rows: []}} -> {:error, :enrollment_not_found}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  def workspace_id_for_order(_id), do: {:error, :enrollment_required}

  defp lock_status_to_atom(status) when is_binary(status), do: String.to_existing_atom(status)
  defp lock_status_to_atom(status) when is_atom(status), do: status

  # ── 信号 payload（SignalEmitter 契约：fn changeset, record -> map，只组装业务键；
  # idempotency_key / workspace_id 由 emitter 统一注入，plan 2026-08-14-003 Q12）──

  # submitted / completed 全量 payload：completed 的幂等键由 emitter 按
  # "<type>:<record_id>" 注入（同报名设计文档 §4.2 约定逐值一致）。
  # confirm 路径 context 无 enrollment_policy（仅 prepare_create 写入）→ 键落 nil。
  def signal_payload(changeset, enrollment) do
    policy = changeset.context[:enrollment_policy]

    enrollment
    |> base_enrollment_payload()
    |> Map.merge(%{
      "event_id" => enrollment.event_id,
      "course_id" => enrollment.course_id,
      "enrollment_policy" => policy && to_string(policy)
    })
  end

  # approved / rejected 只带基础键（区别于 submitted/completed 的全量形状）。
  def approval_payload(_changeset, enrollment), do: base_enrollment_payload(enrollment)

  # 免缴审计 metadata（LogAdminAction 契约：public 远程捕获）
  def waive_log_metadata(_changeset, enrollment) do
    %{
      "event_id" => enrollment.event_id,
      "course_id" => enrollment.course_id,
      "user_id" => enrollment.user_id
    }
  end

  # SignalEmitter skip_unless 谓词：create 仅自动确认（confirmed）时发 completed。
  def confirmed?(_changeset, enrollment), do: enrollment.status == :confirmed

  defp base_enrollment_payload(enrollment) do
    %{
      "enrollment_id" => enrollment.id,
      "user_id" => enrollment.user_id,
      "status" => to_string(enrollment.status)
    }
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:admission)
    table_columns([:id, :workspace_id, :user_id, :event_id, :course_id, :status, :inserted_at])
  end
end
