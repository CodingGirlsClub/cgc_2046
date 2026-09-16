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

      # ends_at 是 no-show 结算的资金扳机（KTD7）：存在未终态押金单时禁止前移
      # ——否则把 ends_at 改到 48h 前即触发下一拍全量不可逆没收（adversarial P1）
      deposit_enabled == true and ends_at_moved_earlier?(changeset) and
          not offering_matches?(changeset) ->
        {:error,
         Cgc2046.Errors.BusinessError.exception(
           message: "cannot move ends_at earlier while active deposit orders exist",
           code: "event_ends_at_frozen",
           fields: [:ends_at]
         )}

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

  # ends_at 前移 = 新值 < 旧值
  defp ends_at_moved_earlier?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :ends_at) and
      not is_nil(Ash.Changeset.get_data(changeset, :ends_at)) and
      not is_nil(Ash.Changeset.get_attribute(changeset, :ends_at)) and
      DateTime.compare(
        Ash.Changeset.get_attribute(changeset, :ends_at),
        Ash.Changeset.get_data(changeset, :ends_at)
      ) == :lt
  end

  # 有无非终态押金单（paid/refunding/refund_failed）→ 冻结守卫的触发条件。
  # 跨域只读（Events → Payments Order），单次点查（Event update 低频）。
  defp offering_matches?(changeset) do
    event_id = Ash.Changeset.get_data(changeset, :id)

    case Cgc2046.Repo.query(
           """
           SELECT 1 FROM payments_orders
           WHERE enrollment_id IN (SELECT id FROM enrollments WHERE event_id = $1)
             AND order_kind = 'deposit'
             AND status IN ('paid', 'refunding', 'refund_failed')
           LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(event_id)]
         ) do
      {:ok, %{rows: []}} -> true
      {:ok, %{rows: [_ | _]}} -> false
      _ -> false
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
  押金重开必须显式携带金额的稳定业务错误（#616 单源，MCP 快速失败复用）。
  """
  def deposit_amount_must_be_explicit_error,
    do: domain_error(:deposit_amount_must_be_explicit, :deposit_amount_cents)

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
end
