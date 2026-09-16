defmodule Cgc2046.Repo.Migrations.AddPricingRequiresStartsAtChecks do
  @moduledoc """
  #543 定价锚点兜底：`pricing_enabled = true` ⇒ `starts_at` 非空
  （events / courses 各一条，自助取消「活动开始前全额退」的锚点）。

  与 `20260916170000_add_events_deposit_anchor_checks.exs` 同类同纪律
  （#587/#608 先例），**有意不做两段式 VALIDATE**：

  - `NOT VALID` 只跳过存量行扫描，新写入与存量行的 UPDATE 立即受约束；
  - 迁移在任何环境都不会因历史脏行失败；存量纳入需先人工回填
    `starts_at`（无法靠数据迁移编造开课时间），再单开 VALIDATE 迁移；
  - 域校验单源在 `Offering.PriceTiersValidation`（Event/Course 共享，
    只拦本次写入造成的新违规）；本 CHECK 无条件兜底（含未知裸 SQL 路径），
    冲突经各自 `handle_write_error/2` 映射稳定 code
    `pricing_starts_at_required`。

  ## 存量普查（2026-09-16，本地 dev 实测）

  dev 库 `pricing_enabled AND starts_at IS NULL`：events 1 行、courses 3 行
  （测试种子/手工布置残留）。这些存量脏行在迁移后**整行不可 UPDATE**（同
  押金 #634 脏行语义），回填或清理另行处理；生产未普查——NOT VALID 使本
  迁移对任何存量状态安全。

  ## 形态

  单事务 2×`ALTER TABLE ... ADD CONSTRAINT ... NOT VALID`：不扫表，
  ACCESS EXCLUSIVE 仅覆盖目录更新（毫秒级），失败可干净重跑。约束名与
  资源 `check_constraints` DSL 声明逐字一致（`mix ash_postgres.generate_migrations
  --check` 零漂移）。`pricing_enabled` 是 NOT NULL DEFAULT false，无 NULL 分支；
  若将来放开可空，CHECK 对 NULL 求值为 NULL = 放行，属预期。
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE events
      ADD CONSTRAINT events_pricing_requires_starts_at
      CHECK (NOT (pricing_enabled AND starts_at IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE courses
      ADD CONSTRAINT courses_pricing_requires_starts_at
      CHECK (NOT (pricing_enabled AND starts_at IS NULL)) NOT VALID
    """)
  end

  def down do
    execute("ALTER TABLE events DROP CONSTRAINT IF EXISTS events_pricing_requires_starts_at")

    execute("ALTER TABLE courses DROP CONSTRAINT IF EXISTS courses_pricing_requires_starts_at")
  end
end
