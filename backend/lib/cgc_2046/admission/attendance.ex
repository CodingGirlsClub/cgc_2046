defmodule Cgc2046.Admission.Attendance do
  @moduledoc """
  到场事实（押金制 KTD4/KTD11；R6、R11；#508 最小核销载体）。

  每个报名（Enrollment）至多一行：`identity :unique_enrollment` 的
  `attendances_unique_enrollment_index` 唯一索引即核销幂等承载（review F3：
  幂等落 DB，不靠应用层判重）。核销 = 普通 INSERT，**不声明 upsert**——upsert
  会让第二个并发请求命中更新分支照常执行 after_action（U6 核销即退），打开
  重复退款 CAS 面；普通 INSERT 在冲突时由 data layer 拒绝、after_action 不执行
  （KTD4）。

  ## 核销写路径（`check_in` action）

  1. `EventModerator` / `PlatformAdmin` policy 以 `(event_id 参数, tenant)` 直读
     Event 判定授权（`Admission.Policies.EventModerator`，fail-closed）；
  2. `before_action` 按 `(event_id, code)` 定位 `confirmed` 报名——不存在、
     非 confirmed（`payment_pending` / `pending` / `cancelled` 等）或码不匹配
     统一返回「码无效」（`attendance_invalid_code`，不区分原因，不给码探测面）；
  3. 对该报名调 `Enrollment.lock_for_order/1`（`SELECT … FOR UPDATE`）——与下单/
     落账 worker 共用同一条报名行锁（KTD6 锁序），锁内重读 status 二次确认
     confirmed（锁前查询到锁之间的并发取消不留窗口）；
  4. 落行：`workspace_id` / `event_id` 取锁定行的真实值，`operator_id` = actor，
     `checked_in_at` = 落行时刻，`method` = scan / manual；
  5. 同事务记 `AdminActionLog :attendance_check_in`（actor = 核销人）。

  唯一索引冲突（同一报名已核销）经 `error_handler` 映射为
  `attendance_already_checked_in`——本表唯一索引只有 enrollment_id 一条，
  任何 unique 冲突都等价「已核销」。

  ## 授权面

  写面仅 `check_in`：Event 主理人（Event 级 seam，非 workspace 成员）或目标
  workspace Owner/Admin（`Moderators.can_moderate?/2`）＋ PlatformAdmin
  （跨租户治理兜底，与同域 `waive_payment` 同款）。读面仅 PlatformAdmin
  （`/ops` 观测，同 `CapacityLedger`）；无 GraphQL 自动读面——核销结果经
  手写 mutation `checkInEnrollment` 返回。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Admission

  alias Cgc2046.Admission.Enrollment

  # method 白名单（:atom 参数 cast 走 String.to_existing_atom，未知值即 :error，
  # 不开 unsafe_to_atom?——backend/AGENTS.md 纪律）
  @methods [:scan, :manual]

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid, allow_nil?: false, public?: true, writable?: false)
    attribute(:enrollment_id, :uuid, allow_nil?: false, public?: true, writable?: false)
    attribute(:event_id, :uuid, allow_nil?: false, public?: true, writable?: false)

    attribute(:operator_id, :uuid,
      allow_nil?: false,
      public?: true,
      writable?: false,
      description: "核销人（主理人 / Owner·Admin / 平台管理员）"
    )

    attribute(:checked_in_at, :utc_datetime, allow_nil?: false, public?: true, writable?: false)

    attribute(:method, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [one_of: @methods],
      description: "核销方式：scan（扫码）/ manual（手输码）"
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
    belongs_to(:enrollment, Cgc2046.Admission.Enrollment, define_attribute?: false)
    belongs_to(:event, Cgc2046.Events.Event, define_attribute?: false)

    belongs_to(:operator, Cgc2046.Accounts.User,
      define_attribute?: false,
      source_attribute: :operator_id
    )
  end

  identities do
    # all_tenants?：核销幂等的真值域是「报名」本身（报名天然只属于一个 workspace），
    # 唯一索引因此不拼租户列——跨租户同 enrollment 的第二行同属违规，一并拒绝。
    identity :unique_enrollment, [:enrollment_id] do
      all_tenants?(true)
    end
  end

  actions do
    defaults([:read])

    create :check_in do
      description("按 6 位核销码为 confirmed 报名生成唯一 Attendance 记录（R6/R11）")

      # 客户端只给事实（哪场、哪个码、扫码还是手输）；enrollment_id / workspace_id /
      # operator_id / checked_in_at 全部由服务端从锁定行与 actor 派生。
      accept([])

      argument(:event_id, :uuid, allow_nil?: false)
      argument(:code, :string, allow_nil?: false, description: "6 位核销码")
      argument(:method, :atom, allow_nil?: false, constraints: [one_of: @methods])

      # attendances 唯一索引只有 enrollment_id 一条 → unique 冲突即「已核销」
      error_handler({__MODULE__, :handle_create_error, []})

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &prepare_check_in/1)
      end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :attendance_check_in,
         target_type: :enrollment,
         target_id: &__MODULE__.log_target_id/2,
         metadata: &__MODULE__.log_metadata/2}
      )
    end
  end

  postgres do
    table("attendances")
    repo(Cgc2046.Repo)
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸）
    resource_group(:admission)

    table_columns([
      :id,
      :workspace_id,
      :event_id,
      :enrollment_id,
      :operator_id,
      :method,
      :checked_in_at
    ])
  end

  graphql do
    # 手写 mutation checkInEnrollment（graphql_schema.ex）是唯一 GraphQL 入口：
    # 本资源不注册任何 query/mutation，Absinthe 的可达性裁剪因此不会把
    # Attendance 类型写进 SDL（web/小程序 codegen 工件零扰动）。type 名仍需
    # 声明——AshGraphql 的 filter/sort 类型标识由它派生（缺失即生成
    # `_filter_input` 撞名，编译期报 "Type name FilterInput is not unique"）。
    type(:attendance)
  end

  policies do
    policy action(:check_in) do
      authorize_if(Cgc2046.Admission.Policies.EventModerator)
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 观测读面（#209 / CapacityLedger 同款）：platform_admin 可读，非 admin default-deny
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  # ── 核销入口（手写 mutation 的域编排：event → tenant 解析 + create）─────────

  @doc """
  核销：按 `(event_id, code, method)` 生成该报名的 Attendance 行。

  tenant 由 event 自身解析（客户端不传租户；policy 会再校验
  `event.workspace_id == tenant`），actor 与授权判定在 policy 层。
  返回 `{:ok, %Attendance{}}` / `{:error, Ash.Error.t()}`——错误形状与
  `Ash.create/2` 一致（业务错误经 `AshGraphql.Errors.to_errors` 序列化），
  event 不存在（或不可解析）时与码无效同码返回（同一「核销失败」桶，
  不给调用方额外枚举面）。
  """
  @spec check_in(term(), term(), term(), term()) ::
          {:ok, __MODULE__.t()} | {:error, Ash.Error.t()}
  def check_in(event_id, code, method, actor) do
    with {:ok, tenant} <- event_workspace(event_id) do
      __MODULE__
      |> Ash.Changeset.for_create(:check_in, %{
        event_id: event_id,
        code: code,
        method: method
      })
      |> Ash.create(tenant: tenant, actor: actor)
    end
  end

  # Event 是 global?(true) 租户资源，PK 全局唯一——直读取 workspace_id 作为本次
  # 核销的 tenant（同 SpeakerInvitations / 播报订阅方的直读先例）。
  defp event_workspace(event_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(event_id),
         {:ok, %{workspace_id: workspace_id}} <-
           Ash.get(Cgc2046.Events.Event, uuid, authorize?: false),
         true <- is_binary(workspace_id) do
      {:ok, workspace_id}
    else
      _ -> {:error, invalid_code_error()}
    end
  end

  # ── 唯一冲突 → 业务错误（identity/error_handler 三件套）──────────────────

  # error_handler 返回值即入列的错误：unique 冲突（唯一索引
  # attendances_unique_enrollment_index）映射为已核销；其他错误原样上抛
  # （DB 断连等真实故障不含 constraint_type: :unique 键）。
  def handle_create_error(_changeset, error) do
    if unique_conflict?(error) do
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(:already_checked_in),
        code: domain_error_code(:already_checked_in),
        fields: [:enrollment_id]
      )
    else
      error
    end
  end

  defp unique_conflict?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &unique_conflict?/1)
  end

  defp unique_conflict?(%Ash.Error.Changes.InvalidAttribute{private_vars: private_vars}) do
    Keyword.get(private_vars || [], :constraint_type) == :unique
  end

  defp unique_conflict?(_), do: false

  # ── before_action：定位 + 行锁 + 落行属性 ─────────────────────────────────

  defp prepare_check_in(changeset) do
    event_id = Ash.Changeset.get_argument(changeset, :event_id)
    code = Ash.Changeset.get_argument(changeset, :code)
    actor = get_in(changeset.context, [:private, :actor])

    with {:ok, enrollment_id} <- confirmed_enrollment_id(event_id, code),
         # 锁内重读是裁决口径：锁前的定位查询与拿锁之间若有并发取消/落账，
         # 此处 status 以 locked 行的持久态为准（与下单链同款用法）。
         {:ok, %{status: :confirmed} = locked} <- Enrollment.lock_for_order(enrollment_id) do
      changeset
      |> Ash.Changeset.force_change_attribute(:enrollment_id, locked.id)
      |> Ash.Changeset.force_change_attribute(:workspace_id, locked.workspace_id)
      |> Ash.Changeset.force_change_attribute(:event_id, locked.event_id)
      |> Ash.Changeset.force_change_attribute(:operator_id, actor && Map.get(actor, :id))
      |> Ash.Changeset.force_change_attribute(:checked_in_at, DateTime.utc_now())
      |> Ash.Changeset.force_change_attribute(
        :method,
        Ash.Changeset.get_argument(changeset, :method)
      )
    else
      _ -> add_domain_error(changeset, :invalid_code)
    end
  end

  # 同场唯一码定位 confirmed 报名（`enrollments_unique_check_in_code_index` 支撑）。
  # 无锁读——锁由随后的 lock_for_order/1 承担（KTD6 锁序：报名行锁点唯一）。
  defp confirmed_enrollment_id(event_id, code) when is_binary(event_id) and is_binary(code) do
    case Cgc2046.Repo.query(
           """
           SELECT id FROM enrollments
           WHERE event_id = $1 AND check_in_code = $2 AND status = 'confirmed'
           LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(event_id), code]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, Ecto.UUID.load!(id)}
      {:ok, %{rows: []}} -> {:error, :invalid_code}
      {:error, reason} -> {:error, {:database, reason}}
    end
  end

  defp confirmed_enrollment_id(_event_id, _code), do: {:error, :invalid_code}

  # ── 审计 metadata（LogAdminAction 契约：public 远程捕获）──────────────────

  def log_target_id(_changeset, attendance), do: attendance.enrollment_id

  def log_metadata(_changeset, attendance) do
    %{
      "event_id" => attendance.event_id,
      "method" => to_string(attendance.method)
    }
  end

  # ── 错误文案（i18n Phase 0：BusinessError 携带稳定 code，前端按 code 查文案）──

  defp add_domain_error(changeset, reason) do
    Ash.Changeset.add_error(
      changeset,
      Cgc2046.Errors.BusinessError.exception(
        message: domain_error_message(reason),
        code: domain_error_code(reason)
      )
    )
  end

  defp invalid_code_error do
    Cgc2046.Errors.BusinessError.exception(
      message: domain_error_message(:invalid_code),
      code: domain_error_code(:invalid_code)
    )
  end

  defp domain_error_message(:invalid_code),
    do: "check-in code is invalid for this event"

  defp domain_error_message(:already_checked_in),
    do: "this enrollment has already been checked in"

  defp domain_error_code(:invalid_code), do: "attendance_invalid_code"
  defp domain_error_code(:already_checked_in), do: "attendance_already_checked_in"
end
