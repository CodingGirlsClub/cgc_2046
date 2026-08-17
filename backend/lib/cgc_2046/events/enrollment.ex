defmodule Cgc2046.Events.Enrollment do
  @moduledoc """
  Event/Course 报名资源。

  核心并发不变量由数据库承担：目标活动的 `confirmed_count` 通过条件 UPDATE
  占位，InviteBatch 配额通过 `remaining_quota > 0` 条件 UPDATE 扣减，报名本身
  由两个部分唯一索引防重复。所有写都位于 Ash action 事务内，后续步骤失败会回滚
  已执行的计数更新。

  ## learning 锚定（唯一真源，架构深化 E；plan 2026-08-17-004）

  「learning run 锚定到哪条 Enrollment」的唯一读取面 = `anchor/1`（+ 双键提取
  `anchored_id/1`）。三消费方（Workflows→Events 依赖方向）：
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
    domain: Cgc2046.Api

  require Logger

  alias Cgc2046.ApprovalClaim

  @submitted_signal "enrollment.submitted"
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
    attribute(:cancelled_at, :utc_datetime, public?: true, writable?: false)

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
          |> Enum.group_by(& &1.workspace_id)
          |> Enum.reduce(%{}, fn {workspace_id, rows}, acc ->
            ids_by_kind =
              %{
                event: rows |> Enum.map(& &1.event_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
                course: rows |> Enum.map(& &1.course_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
              }
              |> Enum.reject(fn {_kind, ids} -> ids == [] end)
              |> Map.new()

            Map.merge(
              acc,
              Cgc2046.Events.Offering.fetch_titles_by_ids(ids_by_kind, workspace_id)
            )
          end)

        Enum.map(enrollments, fn enrollment ->
          snapshot_target_title(enrollment) ||
            target_title_from_offerings(enrollment, titles)
        end)
      end
    )
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)
    belongs_to(:course, Cgc2046.Events.Course, define_attribute?: false)
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
    belongs_to(:workflow_run, Cgc2046.Workflows.WorkflowRun, define_attribute?: false)
    belongs_to(:invite_batch, Cgc2046.Events.InviteBatch, define_attribute?: false)

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
  end

  actions do
    defaults([:read])

    read :my_enrollments do
      description("当前用户跨工作台的报名记录")
      filter(expr(user_id == ^actor(:id)))
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

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_create/1)
      end)

      # 信号经 SignalEmitter 事务内 outbox 入队（plan 2026-08-14-003 Q6）：
      # 任何策略都发 submitted；open/invite_only 自动确认（confirmed）时再发
      # completed（KTD1/R3），两个 after_action 按声明顺序入队。
      change(
        {Cgc2046.Changes.SignalEmitter,
         type: @submitted_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        {Cgc2046.Changes.SignalEmitter,
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
        {Cgc2046.Changes.SignalEmitter,
         type: @approved_signal, payload: &__MODULE__.approval_payload/2}
      )

      change(
        {Cgc2046.Changes.SignalEmitter,
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
        {Cgc2046.Changes.SignalEmitter,
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
        {Cgc2046.Changes.SignalEmitter,
         type: @completed_signal, payload: &__MODULE__.signal_payload/2}
      )

      change(
        {Cgc2046.Changes.LogAdminAction,
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
        {Cgc2046.Changes.SignalEmitter,
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
        "course_id IS NOT NULL AND status IN ('pending', 'payment_pending', 'confirmed')"
    )
  end

  policies do
    policy action(:create_enrollment) do
      forbid_if(Cgc2046.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action([:confirm_enrollment, :reject_enrollment]) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    policy action(:waive_payment) do
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end

    policy action(:cancel) do
      forbid_if(Cgc2046.Policies.PlatformAdmin)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:my_enrollments) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(Cgc2046.Policies.WorkspaceActorIsOwnerOrAdmin)
      authorize_if(Cgc2046.Policies.PlatformAdmin)
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
      list(:enrollments, :read)
      list(:my_enrollments, :my_enrollments)
    end

    mutations do
      create(:create_enrollment, :create_enrollment)
      update(:confirm_enrollment, :confirm_enrollment)
      update(:reject_enrollment, :reject_enrollment)
      update(:cancel_enrollment, :cancel)
      update(:waive_payment, :waive_payment)
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

  defp prepare_create(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    course_id = Ash.Changeset.get_attribute(changeset, :course_id)
    actor = changeset.context[:private][:actor]

    with {:ok, target_kind, target_id} <- exactly_one_target(event_id, course_id),
         {:ok, target} <- eligible_target(target_kind, target_id, actor),
         {:ok, tenant} <- resolve_tenant(changeset.tenant, target.workspace_id),
         {:ok, attrs} <- prepare_policy(changeset, target_kind, target_id, target, tenant),
         {:ok, attrs} <- put_tier_selection(changeset, target, attrs) do
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

  defp auto_confirm_status(%{pricing_enabled: true}), do: :payment_pending
  defp auto_confirm_status(_target), do: :confirmed

  # 收费报名的档位选择（KTD9/R2）：tier_id 必填且当前可售，存 submission_payload
  # 供下单链快照（U5 resolve_tier）；免费目标忽略 tier_id（R4）。
  defp put_tier_selection(changeset, %{pricing_enabled: true, price_tiers: tiers}, attrs) do
    tier_id = Ash.Changeset.get_argument(changeset, :tier_id)

    with true <- (is_binary(tier_id) and tier_id != "") || {:error, :tier_id_required},
         {:ok, tier} <- Cgc2046.Events.PriceTier.find(tiers, tier_id),
         true <-
           Cgc2046.Events.PriceTier.available?(tier, DateTime.utc_now()) ||
             {:error, :tier_not_available} do
      payload =
        changeset
        |> Ash.Changeset.get_attribute(:submission_payload)
        |> Kernel.||(%{})
        |> Map.put("tier_id", tier_id)

      {:ok, Map.put(attrs, :submission_payload, payload)}
    end
  end

  defp put_tier_selection(_changeset, _target, attrs), do: {:ok, attrs}

  defp prepare_confirm(changeset) do
    now = DateTime.utc_now()
    actor = changeset.context[:private][:actor]

    with {:ok, kind, target_id} <- target_from_record(changeset.data),
         {:ok, sequence} <- reserve_capacity(kind, target_id),
         {:ok, target_status} <- confirm_target_status(kind, target_id),
         {:ok, 1} <- claim_pending(changeset.data.id, target_status, actor.id, now, nil) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, target_status)
      |> Ash.Changeset.force_change_attribute(:capacity_seq, sequence)
      |> Ash.Changeset.force_change_attribute(:approved_by, actor.id)
      |> Ash.Changeset.force_change_attribute(:approved_at, now)
      |> stash_target_policy(kind, target_id)
    else
      {:ok, 0} -> add_domain_error(changeset, :already_processed)
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # 审批通过后的落点（KTD6-3）：收费目标占位后进 payment_pending（支付完成才
  # confirmed，由回调 worker 推进）；免费目标直接 confirmed（R4 现状不变）。
  defp confirm_target_status(kind, target_id) do
    table = target_table(kind)

    case Cgc2046.Repo.query("SELECT pricing_enabled FROM #{table} WHERE id = $1", [
           Cgc2046.Repo.uuid!(target_id)
         ]) do
      {:ok, %{rows: [[pricing_enabled]]}} ->
        {:ok, if(pricing_enabled, do: :payment_pending, else: :confirmed)}

      {:ok, %{rows: []}} ->
        {:error, :target_not_open_or_registration_closed}

      {:error, reason} ->
        {:error, {:database, reason}}
    end
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
    now = DateTime.utc_now()

    with {:ok, capacity_target} <- claim_cancellable(changeset.data.id, now),
         :ok <- release_capacity(capacity_target),
         {:ok, _voided} <- void_pending_orders(changeset.data.id, "enrollment_cancelled") do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :cancelled)
      |> Ash.Changeset.force_change_attribute(:cancelled_at, now)
    else
      {:error, reason} -> add_domain_error(changeset, reason)
    end
  end

  # R12/e2e #1：取消/免缴在离开占位态的同一事务内作废报名关联 pending 订单
  # （报名已流转而订单仍 pending = 「无占位却有未付单」脏窗口：待收统计失真，
  # 且本地作废不关渠道单、QR 仍可被支付——迟到收款由落账 worker 走作废单
  # 自动退款分支兜底，AE2 语义）。cancelled 是终态，部分唯一索引放行后续
  # 新报名的新订单。
  defp void_pending_orders(enrollment_id, cancel_reason) do
    case Cgc2046.Repo.query(
           "UPDATE payments_orders SET status = 'cancelled', cancel_reason = $2, updated_at = NOW() WHERE enrollment_id = $1 AND status = 'pending'",
           [Cgc2046.Repo.uuid!(enrollment_id), cancel_reason]
         ) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # 支付落账（U7，KTD12）：CAS payment_pending → confirmed（免缴/过期/取消竞态
  # 由 num_rows=0 上抛给 worker 走自动退款分支）。
  defp prepare_settle_paid(changeset) do
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

    with {:ok, 1} <- claim_waive(changeset.data.id, actor.id, now),
         {:ok, _voided} <- void_pending_orders(changeset.data.id, "waived") do
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
    sql = """
    SELECT workspace_id, enrollment_policy, pricing_enabled, price_tiers
    FROM #{table}
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > NOW())
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
      {:ok, %{rows: [[workspace_id, policy, pricing_enabled, price_tiers]]}} ->
        case Map.get(@enrollment_policy_atoms, policy) do
          nil ->
            {:error, {:unknown_enrollment_policy, policy}}

          enrollment_policy ->
            {:ok,
             %{
               workspace_id: Ecto.UUID.load!(workspace_id),
               enrollment_policy: enrollment_policy,
               pricing_enabled: pricing_enabled,
               price_tiers: price_tiers || []
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

  defp reserve_capacity(kind, id) do
    table = target_table(kind)

    sql = """
    UPDATE #{table}
    SET confirmed_count = confirmed_count + 1, updated_at = NOW()
    WHERE id = $1 AND status = 'open'
      AND (registration_deadline IS NULL OR registration_deadline > NOW())
      AND (capacity IS NULL OR confirmed_count < capacity)
    RETURNING confirmed_count
    """

    case Cgc2046.Repo.query(sql, [Cgc2046.Repo.uuid!(id)]) do
      {:ok, %{rows: [[sequence]]}} -> {:ok, sequence}
      {:ok, %{rows: []}} -> {:error, :capacity_full_or_registration_closed}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

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

  defp release_capacity(nil), do: :ok

  defp release_capacity({kind, target_id}) do
    table = target_table(kind)

    case Cgc2046.Repo.query(
           "UPDATE #{table} SET confirmed_count = confirmed_count - 1 WHERE id = $1 AND confirmed_count > 0",
           [Cgc2046.Repo.uuid!(target_id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :capacity_counter_invalid}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  # GraphQL 入口不注入 tenant（nil 时从目标派生）；显式传错 tenant 仍拒绝（防跨 workspace 越权）
  defp resolve_tenant(nil, workspace_id), do: {:ok, workspace_id}
  defp resolve_tenant(tenant, tenant), do: {:ok, tenant}
  defp resolve_tenant(_, _), do: {:error, :target_tenant_mismatch}

  defp target_table(:event), do: "events"
  defp target_table(:course), do: "courses"

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message: domain_error_message(reason)
    )
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

  defp domain_error_message(:already_processed), do: "enrollment has already been processed"

  defp domain_error_message({:unknown_enrollment_policy, _policy}),
    do: "target has an unknown enrollment policy"

  defp domain_error_message(:not_expired_pending),
    do: "enrollment is not an expired pending record"

  defp domain_error_message(:not_payment_pending),
    do: "enrollment is not awaiting payment"

  defp domain_error_message(:capacity_counter_invalid), do: "capacity counter is invalid"
  defp domain_error_message({:database, _reason}), do: "database operation failed"
  defp domain_error_message(reason), do: inspect(reason)

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
    resource_group(:events)
    table_columns([:id, :workspace_id, :user_id, :event_id, :course_id, :status, :inserted_at])
  end
end
