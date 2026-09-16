defmodule Cgc2046.Repo.Migrations.AddEventsDepositAnchorChecks do
  @moduledoc """
  #608 / #623 押金锚点兜底：`deposit_enabled = true` ⇒ 报名截止 / `ends_at` /
  正金额三者必须在位（no-show 结算锚点 KTD7 + 自助取消锚点 #587）。

  与 `20260914093000_add_events_payment_mode_exclusive_check.exs` /
  `20260916044210_add_events_deposit_excludes_price_tiers_check.exs` 同类（KTD3/#597
  先例），但**有意不做两段式 `VALIDATE`**。

  ## 为什么一律 `NOT VALID`

  `NOT VALID` 只跳过存量行扫描，新写入与存量行的 UPDATE 立即受约束。普查
  （2026-09-16，主库 `BEGIN READ ONLY` + 本地 dev）：

  - 生产主库 events 8 行：押金开 + 无报名截止 0 / 押金开 + 无 `ends_at` 0 /
    押金开 + 金额缺失或非正 0 → 本迁移在生产零违规。
  - 本地 dev 库 17 场（11 场押金开）：押金开 + 无 `ends_at` 2 行（其中 1 行
    同时无报名截止），金额违规 0。带校验的 `ADD CONSTRAINT` 会让 dev（以及任何
    存在历史脏行的环境）`mix ecto.migrate` 直接失败。

  因此本迁移**不扫描存量、不 `VALIDATE`**：迁移在任何环境都不会因历史脏行失败。
  代价与后续（issue #634）：NOT VALID 对存量行的**每次 UPDATE** 同样生效 →
  脏行在回填前"整行不可更新"（生产 0 行无影响；dev 2 行）。存量纳入校验需先
  人工回填（`ends_at` 无法靠数据迁移编造），再单开迁移
  `VALIDATE CONSTRAINT` ×3；届时一并评估规则传播/挂载路径的前置守卫收口
  （`RuleInheritance.ensure_deposit_invariant/1` 目前只含 `registration_deadline`）。
  #634 还负责把本条 NOT VALID 两段式纪律补进 `backend/AGENTS.md`（本 PR 不改文档）。

  ## 形态

  单事务 3×`ALTER TABLE ... ADD CONSTRAINT ... NOT VALID`（不用
  `@disable_ddl_transaction` + 幂等 DO 块）：`NOT VALID` 不扫表，ACCESS EXCLUSIVE
  仅覆盖目录更新（毫秒级），单事务保证"三条全上或全不上"，失败可干净重跑。
  两段式样板（`20260902000000_add_occupancy_nonnegative_check.exs`）的存在理由是
  `VALIDATE` 的全表扫描——本迁移有意不做。

  判据与 `Events.PaymentModeValidation` 域校验、`Event.handle_write_error/2`
  的五条显式按名分派同源；约束名与资源 `check_constraints` DSL 声明逐字一致
  （`mix ash_postgres.generate_migrations --check` 零漂移）。`deposit_enabled` 是
  NOT NULL DEFAULT false（`20260913155651`），无 NULL 分支；若将来放开可空，
  CHECK 对 NULL 求值为 NULL = 放行，属预期。
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE events
      ADD CONSTRAINT events_deposit_requires_registration_deadline
      CHECK (NOT (deposit_enabled AND registration_deadline IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE events
      ADD CONSTRAINT events_deposit_requires_ends_at
      CHECK (NOT (deposit_enabled AND ends_at IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE events
      ADD CONSTRAINT events_deposit_requires_positive_amount
      CHECK (
        NOT (deposit_enabled AND (deposit_amount_cents IS NULL OR deposit_amount_cents <= 0))
      ) NOT VALID
    """)
  end

  def down do
    execute(
      "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_deposit_requires_registration_deadline"
    )

    execute("ALTER TABLE events DROP CONSTRAINT IF EXISTS events_deposit_requires_ends_at")

    execute(
      "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_deposit_requires_positive_amount"
    )
  end
end
