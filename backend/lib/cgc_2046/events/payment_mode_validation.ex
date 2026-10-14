defmodule Cgc2046.Events.PaymentModeValidation do
  @moduledoc """
  缴费模式三态互斥校验（Event 押金制 KTD3 / R1 / R3，AE1）。

  免费 / 定价档位 / 押金三态互斥；`deposit_enabled` 与 `pricing_enabled`
  不可同真；**押金开启时 `price_tiers` 必须为空**（#597：否则档位残留会让按
  `tiers` 内容分支的读面与按 `deposit_enabled` 分支的读面自相矛盾）；押金
  开启时 `deposit_amount_cents` 必须为正整数、`ends_at` 非空（no-show 结算
  锚点，KTD7）、`registration_deadline` 非空（自助取消锚点，#587）；**重开
  必须显式携带金额**（#616：`false → true` 而本次写入未带
  `deposit_amount_cents` 会把上一次的旧金额静默复活为实收口径，而确认摘要
  只显示开关翻转）。拒绝时抛
  稳定 `BusinessError` code（#241 契约），前端按 code 查文案表。

  形态选择「显式拒绝」而非「同事务清空档位」（#597 裁决）：清空不进 MCP
  确认流 pending 摘要（摘要由调用方入参生成）→ 确认流会撒谎；且本仓既有原则
  是不静默改写资金配置（见 `Initiatives.RuleInheritance`）。调用方补救 = 同
  一次写带上 `price_tiers: []`。

  并发兜底（两编辑各基于旧值通过资源校验；规则挂载 / 传播路径的 force 写与裸
  SQL 写）由 DB CHECK `events_payment_mode_exclusive` /
  `events_deposit_excludes_price_tiers` / `events_deposit_requires_registration_deadline`
  / `events_deposit_requires_ends_at` / `events_deposit_requires_positive_amount`
  承担，经 `Event.handle_write_error/2` 映射回同一稳定 code（三条锚点 CHECK
  一律 NOT VALID 上线，见 `20260916170000` 迁移 moduledoc）。

  注意覆盖边界：本模块是资源级 `validate`，**先于** `before_action` 执行；
  Initiative 规则挂载（`RuleInheritance.prepare_event_changes` 在 before_action
  里 force_change deposit 字段）不经本模块——其截止日不变量（#587）与
  档位为空不变量（#597）由 `RuleInheritance` 自己判，DB CHECK 是同路径的最后
  兜底。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Errors.BusinessError

  @impl true
  def validate(changeset, _opts, _context) do
    deposit_enabled = Ash.Changeset.get_attribute(changeset, :deposit_enabled)
    pricing_enabled = Ash.Changeset.get_attribute(changeset, :pricing_enabled)

    cond do
      # 互斥是无条件不变量（DB CHECK 同款）：任何写入都拦
      deposit_enabled == true and pricing_enabled == true ->
        {:error, domain_error(:payment_mode_exclusive, :deposit_enabled)}

      # 押金 ⇒ 档位为空（#597）：无条件不变量（DB CHECK 同款）。不做
      # `deposit_config_touched?` 式 scoping——那是为「存量缺口行不被无关编辑
      # 锁死」设的豁免，而本不变量的存量违规行由 CHECK 承担锁死后果，
      # scoping 只是假安慰：回填清空存量后无条件子句才是正确形态。
      # 位置在互斥之后：双真且档位非空时仍先报更根本的互斥。
      deposit_enabled == true and tiers_nonempty?(changeset) ->
        {:error, domain_error(:deposit_price_tiers_conflict, :price_tiers)}

      # 押金重开必须显式携带金额（#616）：false→true 且写前有残留金额、本次
      # 写入未提供 `deposit_amount_cents` → 残留旧金额静默复活。旧值 nil（首开）
      # 不落此子句——由下方 `deposit_amount_required` 以既有 code 承担；显式带
      # 0/负值亦归下方生效值校验。create 不触发（`action_type` 守卫：create 的
      # data struct 字段是 schema default false，不是落库值）。规则挂载/传播
      # 路径不经本模块（见 moduledoc 覆盖边界），其两列同写天然携带金额。
      deposit_enabled == true and deposit_reopening_with_stale_amount?(changeset) and
          not Ash.Changeset.changing_attribute?(changeset, :deposit_amount_cents) ->
        {:error, domain_error(:deposit_amount_must_be_explicit, :deposit_amount_cents)}

      # 配置完整性只在**写入押金相关字段**时要求：存量行（押金已开但 ends_at 为
      # 空的旧数据）不能被无关编辑（改标题/描述）永久锁死。这类行由
      # DepositForfeitWorker 的 deposit_settlement_unanchored Finding 暴露。
      # 注意：本 scoping 只约束**域校验**；三条锚点 DB CHECK 是**无条件**的，
      # 存量脏行在回填前会被 CHECK 挡住任何 UPDATE（生产普查 0 行；dev 2 行，
      # 回填 + VALIDATE 见 issue #634）。
      deposit_enabled == true and deposit_config_touched?(changeset) and
          not positive_integer?(amount(changeset)) ->
        {:error, domain_error(:deposit_amount_required, :deposit_amount_cents)}

      deposit_enabled == true and deposit_config_touched?(changeset) and
          is_nil(Ash.Changeset.get_attribute(changeset, :ends_at)) ->
        {:error, domain_error(:deposit_ends_at_required, :ends_at)}

      deposit_enabled == true and deposit_config_touched?(changeset) and
          is_nil(Ash.Changeset.get_attribute(changeset, :registration_deadline)) ->
        {:error, registration_deadline_required_error()}

      true ->
        :ok
    end
  end

  defp deposit_config_touched?(changeset) do
    Enum.any?([:deposit_enabled, :deposit_amount_cents, :ends_at], fn attribute ->
      Ash.Changeset.changing_attribute?(changeset, attribute)
    end)
  end

  # 重开转移判据（#616）：仅 update；写前 `deposit_enabled == false` 且残留
  # 金额为正整数（开过押金的行由 DB CHECK 保证残留必正）。
  defp deposit_reopening_with_stale_amount?(changeset) do
    changeset.action_type == :update and
      Ash.Changeset.get_data(changeset, :deposit_enabled) == false and
      positive_integer?(Ash.Changeset.get_data(changeset, :deposit_amount_cents))
  end

  # 写后生效值非空即违规（`nil` 是历史畸形值的 fail-closed 侧：一并拒绝）。
  # DB 侧判据见 `events_deposit_excludes_price_tiers`（多一个 `NOT pricing_enabled`：
  # 双真行由 I1 约束唯一命中，保证 handle_write_error/2 的归因不歧义；本 cond 用
  # 子句顺序达到同样效果——I1 在前）。
  defp tiers_nonempty?(changeset),
    do: Ash.Changeset.get_attribute(changeset, :price_tiers) not in [nil, []]

  # `ends_at` 前移判定（纯值对，供**锁内**守卫复用）。
  #
  # 与 `registration_deadline` 的 nil 语义**相反**，不可共用：`ends_at` 为 nil 表示
  # **不触发没收**（`DepositForfeitWorker` 候选查询要求 `ends_at IS NOT NULL`），
  # 即押金永久滞留，属 KTD7 定义的异常态（由 `deposit_settlement_unanchored`
  # Finding 暴露）。故 `nil → 具体值`（含过去值）是**运维补锚的修复动作**，必须
  # 放行——拦掉会永久锁死这类场的押金（`DepositForfeitWorkerTest`「锚点补回后
  # Finding 自消」钉的正是这条路径）。
  #
  # 「先置空再设过去值」在 ends_at 上不构成额外风险：置空本身不改变结算行为
  # （仍不没收），且带押金开启态置空已被 `events_deposit_requires_ends_at` 校验与
  # DB CHECK 挡住。真正要拦的是「有锚点的场把锚点前移到 48h 前」→ 下一拍全量
  # 不可逆没收。
  @spec ends_at_moved_earlier?(term(), term()) :: boolean()
  def ends_at_moved_earlier?(nil, _new), do: false
  def ends_at_moved_earlier?(_old, nil), do: false
  def ends_at_moved_earlier?(old, new), do: compare_after_normalize(old, new)

  # 归一后比较：本判据被两条来源不同的路径共用——资源级 changeset 给 `DateTime`
  # （`:utc_datetime` 属性的 Ash 形态），而 `RuleInheritance` 的裸 SQL 行给
  # Postgrex 解出的 `NaiveDateTime`。两者直接喂 `DateTime.compare/2` 会
  # FunctionClauseError（实测踩坑），故统一归一到 DateTime（UTC）再比。
  defp compare_after_normalize(old, new),
    do: DateTime.compare(to_datetime(new), to_datetime(old)) == :lt

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  # ── 资金锚点冻结判据的共享面（RuleInheritance 复用）────────────────────────
  #
  # `RuleInheritance` 的两条写入路径（锁死规则传播走裸 SQL、挂载走
  # before_action force）**都不经本模块的资源级 validate**（见 moduledoc 覆盖
  # 边界），因此资源层的冻结守卫对它们无效。把判据与错误构造提到公开面，
  # 让两条继承路径复用同一语义，避免两处各写一份而漂移。

  @doc """
  `registration_deadline` 前移判定（供继承路径复用的纯函数）。

  `nil` 语义与 `ends_at` **相反**，务必不要合并：`Enrollment.before_deadline?/2`
  对 `registration_deadline: nil` 返 `true` —— nil = **退款窗口永不关闭**（最宽松）。

  故 `nil → 具体日期` 只有**新值已过去**才算前移（追溯关闭既有押金单的退款窗口，
  且 `CancelFlow` 判定为假时静默不打款、订单停在 paid）；`nil → 未来日期` 是
  仍留有窗口的放宽，放行。漏掉「nil → 过去值」就等于留出「先置空、再改成过去」
  的两步绕过（`deposit_enabled: false` 的写入不要求锚点非空）。

  具体值 → nil 是放宽（窗口从「某刻关闭」变「永不关闭」），不算前移。
  """
  @spec deadline_moved_earlier?(term(), term()) :: boolean()
  def deadline_moved_earlier?(nil, nil), do: false
  def deadline_moved_earlier?(_, nil), do: false

  def deadline_moved_earlier?(nil, new),
    do: DateTime.compare(to_datetime(new), DateTime.utc_now()) == :lt

  def deadline_moved_earlier?(old, new), do: compare_after_normalize(old, new)

  @doc """
  `ends_at` 前移的稳定业务错误（形状同 `registration_deadline_frozen_error/1`）。
  """
  def ends_at_frozen_error(fields \\ [:ends_at]) do
    BusinessError.exception(
      message: "cannot move ends_at earlier while active deposit orders exist",
      code: "event_ends_at_frozen",
      fields: fields
    )
  end

  @doc "该活动是否存在未终态押金单（paid/refunding/refund_failed）——冻结守卫的触发条件。"
  @spec active_deposit_orders?(term()) :: boolean()
  def active_deposit_orders?(event_id), do: has_active_deposit_orders?(event_id)

  @doc """
  报名截止前移的稳定业务错误（P1 单源，形状同 `registration_deadline_required_error/1`）。

  `fields` 由调用方给——Event 写面 = `[:registration_deadline]`，规则写入 =
  `[event_id: <被拒的场>]`（规则写入必须能定位是哪一场）。
  """
  def registration_deadline_frozen_error(fields \\ [:registration_deadline]) do
    BusinessError.exception(
      message: domain_error_message(:registration_deadline_frozen),
      code: domain_error_code(:registration_deadline_frozen),
      fields: fields
    )
  end

  # 是否存在未终态押金单 → 冻结守卫的触发条件。跨域只读（Events → Payments
  # Order），单次点查（Event update 低频）。
  #
  # **含 `pending`**：待付单的 `expire_at = min(下单 + 2h, 下单时看到的
  # registration_deadline)`（`Order.order_expire_at/1`）是**下单那刻算定的**，
  # 改活动截止不会重算它。故「下单选待付 → 改早截止 → 2h 内付款到账」时，
  # 结算路径的 CAS 只看 `status = 'pending'`（`prepare_mark_paid`，不复查活动
  # 截止）照样落 `paid` —— 而该单的自助退款窗口已被追溯关闭。漏掉 pending
  # 就等于给这条时序留门。
  # create 路径：Event 尚无 id（`get_data(:id) == nil`），必然无既有订单 →
  # 直接 false。不加此子句会在下面的 `Repo.uuid!/1` 抛（实测
  # 「cannot dump given UUID to binary: nil」），把建场整个打挂。
  defp has_active_deposit_orders?(nil), do: false

  defp has_active_deposit_orders?(event_id) do
    case Cgc2046.Repo.query(
           """
           SELECT 1 FROM payments_orders
           WHERE enrollment_id IN (SELECT id FROM enrollments WHERE event_id = $1)
             AND order_kind = 'deposit'
             AND status IN ('pending', 'paid', 'refunding', 'refund_failed')
           LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: []}} -> false
      {:ok, %{rows: [_ | _]}} -> true
      # 查询失败按「有单」处理（fail-closed）：宁可挡住一次合法的锚点前移，
      # 也不放行一次追溯性关闭退款窗口。
      _ -> true
    end
  end

  defp amount(changeset), do: Ash.Changeset.get_attribute(changeset, :deposit_amount_cents)

  defp positive_integer?(amount), do: is_integer(amount) and amount > 0

  @doc """
  押金×定价互斥的稳定业务错误（KTD3 单源）。

  Event 校验（本模块 validate/3）与 DB CHECK 兜底（Event.handle_write_error/2）
  共用同一 message 与 code；`check_constraint` DSL 的 `message:` 是编译期字面量、
  无法引用本函数，故那边保留同文字面量并注释互指。
  """
  def exclusive_error(field), do: domain_error(:payment_mode_exclusive, field)

  @doc """
  押金×档位残留在**并发兜底路径**上的稳定业务错误（#597 单源）。

  正常写入由本模块 `validate/3` 报同一 code；本条供 `Event.handle_write_error/2`
  把 DB CHECK `events_deposit_excludes_price_tiers` 冲突映射成同码同 fields。
  """
  def price_tiers_conflict_error(field), do: domain_error(:deposit_price_tiers_conflict, field)

  @doc """
  押金开启要求活动结束时间非空的稳定业务错误（单源，KTD7 / #608）。

  Event 写面校验（本模块 `validate/3`）与 DB CHECK `events_deposit_requires_ends_at`
  冲突兜底（`Event.handle_write_error/2`）共用同一 message 与 code。
  """
  def deposit_ends_at_required_error, do: domain_error(:deposit_ends_at_required, :ends_at)

  @doc """
  押金开启要求押金金额为正的稳定业务错误（单源，#608）。

  Event 写面校验（本模块 `validate/3`）与 DB CHECK
  `events_deposit_requires_positive_amount` 冲突兜底
  （`Event.handle_write_error/2`）共用同一 message 与 code。
  """
  def deposit_amount_required_error,
    do: domain_error(:deposit_amount_required, :deposit_amount_cents)

  @doc """
  `deposit_enabled = true` 要求报名截止非空的稳定业务错误（单源，#587）。

  Event 写面校验（本模块 `validate/3`）与规则写入路径
  （`Initiatives.RuleInheritance` 的挂载 / 锁死传播守卫）共用同一 message 与
  code；`fields` 由调用方给——Event 写面 = `[:registration_deadline]`，规则
  写入 = `[event_id: <被拒的场>]`（规则写入必须能定位是哪一场，issue #587）。
  """
  def registration_deadline_required_error(fields \\ [:registration_deadline]) do
    BusinessError.exception(
      message: domain_error_message(:deposit_registration_deadline_required),
      code: domain_error_code(:deposit_registration_deadline_required),
      fields: fields
    )
  end

  defp domain_error(reason, field) do
    BusinessError.exception(
      message: domain_error_message(reason),
      code: domain_error_code(reason),
      fields: [field]
    )
  end

  defp domain_error_message(:payment_mode_exclusive),
    do: "an event cannot enable both pricing tiers and deposit"

  defp domain_error_message(:deposit_price_tiers_conflict),
    do: "price tiers must be empty when deposit is enabled"

  defp domain_error_message(:deposit_amount_required),
    do: "a positive deposit_amount_cents is required when deposit is enabled"

  defp domain_error_message(:deposit_amount_must_be_explicit),
    do:
      "re-enabling deposit requires an explicit deposit_amount_cents " <>
        "(the previous amount would otherwise be silently reused)"

  defp domain_error_message(:deposit_ends_at_required),
    do: "ends_at is required when deposit is enabled (settlement anchor)"

  defp domain_error_message(:deposit_registration_deadline_required),
    do: "registration_deadline is required when deposit is enabled (self-cancel cutoff anchor)"

  defp domain_error_message(:registration_deadline_frozen),
    do: "cannot move registration_deadline earlier while active deposit orders exist"

  # 显式子句化（#241）：字面量 code 进错误码契约工件，前端文案表按 code 查
  defp domain_error_code(:payment_mode_exclusive), do: "event_payment_mode_exclusive"

  defp domain_error_code(:deposit_price_tiers_conflict),
    do: "event_deposit_price_tiers_conflict"

  defp domain_error_code(:deposit_amount_required), do: "event_deposit_amount_required"

  defp domain_error_code(:deposit_amount_must_be_explicit),
    do: "event_deposit_amount_must_be_explicit"

  defp domain_error_code(:deposit_ends_at_required), do: "event_deposit_ends_at_required"

  defp domain_error_code(:deposit_registration_deadline_required),
    do: "event_deposit_registration_deadline_required"

  defp domain_error_code(:registration_deadline_frozen),
    do: "event_registration_deadline_frozen"
end
