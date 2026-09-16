defmodule Cgc2046.Repo.Migrations.AddEventsDepositExcludesPriceTiersCheck do
  @moduledoc """
  #597 I2 并发兜底：押金开 ⇒ 档位为空。

  与 `20260914093000_add_events_payment_mode_exclusive_check.exs` 同形（KTD3 先例）：

  - 两步拆成**独立语句**（`@disable_ddl_transaction` → 各自事务）：`ADD ... NOT VALID`
    只取短暂 ACCESS EXCLUSIVE 并立即释放，`VALIDATE` 仅取 SHARE UPDATE EXCLUSIVE
    且不阻塞读写。把 ADD 与 VALIDATE 放进同一个 DO 块会让 ACCESS EXCLUSIVE 一直
    持到 VALIDATE 全表扫描结束，且存量违规行会让整个迁移回滚（NOT VALID 的容忍度
    形同虚设）。
  - 幂等：ADD 前查 `pg_constraint`；已 VALIDATE 的约束重复 VALIDATE 是空操作。

  判据用 `price_tiers <> '[]'::jsonb` 而非 `jsonb_array_length(...) > 0`：后者对畸形
  非数组值（如 `'{}'::jsonb`）会直接报错，前者 fail-closed 视为「非空」拒绝。

  `NOT pricing_enabled` 是**归因必需**（同资源 DSL 注释）：pricing 开 + 档位非空的行
  同时违反两条缴费 CHECK 时，Postgres 只报其中一条（实测报本条），
  `Event.handle_write_error/2` 按约束名分派就会把 I1 误报成 I2。让两条约束不相交后，
  「押金 + 档位非空」行恰好命中一条：pricing 开 → `events_payment_mode_exclusive`；
  pricing 关 → 本约束。

  NULL 语义：`deposit_enabled`（NOT NULL DEFAULT false，20260913155651）与
  `price_tiers`（NOT NULL DEFAULT '[]'::jsonb，squash baseline）都无 NULL 分支；
  若将来放开可空，CHECK 对 NULL 求值为 NULL = 放行，属预期。

  **部署窗口与自愈（owner 裁决 C4；adversarial review #597 P1）**：pre-deploy 钩子在
  **新镜像启动前**跑迁移，此时**旧容器仍在服务**（`.kamal/hooks/pre-deploy`，Kamal
  blue-green）。旧代码没有 I2 校验，所以紧邻的
  `20260916044209_backfill_events_deposit_price_tiers` 提交之后、本迁移 `ADD`
  提交之前，旧 pod 仍可能写入新的「押金开 + 档位非空」行。这类 straggler 会让
  `VALIDATE` 失败，而 09 已记入 `schema_migrations` 不会重跑——重试只会重跑
  `VALIDATE` 并永远失败，需人工清库，部署卡死。

  因此本迁移在 `ADD`（此时约束已对新写入生效，不会再有新违规行）之后、
  `VALIDATE` 之前插入一段**幂等补清**：清掉窗口内的 straggler 并把清理前的
  `id`/`price_tiers` 打进部署日志（可还原）。清库 UPDATE 作用于违规行时，新行版本
  满足判据，故 NOT VALID 约束不阻碍它。执行顺序（每步各自事务）：

  1. `ADD ... NOT VALID`（幂等）；2. straggler 补清（幂等，命中即清 + 落档）；
  3. `VALIDATE`（幂等）。失败重试从 1 重新开始（1 被 IF NOT EXISTS 短路），自愈。

  判据用 `price_tiers <> '[]'::jsonb` 而非 `jsonb_array_length(...) > 0`：后者对畸形
  非数组值（如 `'{}'::jsonb`）会直接报错，前者 fail-closed 视为「非空」拒绝。

  `NOT pricing_enabled` 是**归因必需**（同资源 DSL 注释）：pricing 开 + 档位非空的行
  同时违反两条缴费 CHECK 时，Postgres 只报其中一条（实测报本条），
  `Event.handle_write_error/2` 按约束名分派就会把 I1 误报成 I2。让两条约束不相交后，
  「押金 + 档位非空」行恰好命中一条：pricing 开 → `events_payment_mode_exclusive`；
  pricing 关 → 本约束。

  NULL 语义：`deposit_enabled`（NOT NULL DEFAULT false，20260913155651）与
  `price_tiers`（NOT NULL DEFAULT '[]'::jsonb，squash baseline）都无 NULL 分支；
  若将来放开可空，CHECK 对 NULL 求值为 NULL = 放行，属预期。

  补齐的 straggler 数量按构造极小（pre-deploy 窗口内），故这里逐行 dump 不做分批；
  大批量存量清理在 09（分批 + 聚合日志）。两个迁移与代码必须**同一次部署**：
  CHECK 先行而代码未跟 → 旧 pod 撞上已生效的 CHECK（报 I1 文案，安全但语义不准）；
  代码先行而 CHECK 未落 → 并发写偏斜窗口裸奔。
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  # 与 09 同一判据（自包含：迁移不跨文件共享常量）。
  @residual_predicate "deposit_enabled AND NOT pricing_enabled AND price_tiers <> '[]'::jsonb"

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'events_deposit_excludes_price_tiers' AND conrelid = 'events'::regclass
      ) THEN
        ALTER TABLE events
          ADD CONSTRAINT events_deposit_excludes_price_tiers
          CHECK (
            NOT (deposit_enabled AND NOT pricing_enabled AND price_tiers <> '[]'::jsonb)
          ) NOT VALID;
      END IF;
    END $$;
    """

    clear_deploy_window_stragglers()

    # 幂等：已 VALIDATE 的约束重复 VALIDATE 是空操作
    execute "ALTER TABLE events VALIDATE CONSTRAINT events_deposit_excludes_price_tiers"
  end

  # 部署窗口补清（见 moduledoc）：命中才写，未命中是纯读空操作。
  # 只用 09 的宽判据里「定价关闭」的一半——定价开的双真行违反的是 I1 约束，
  # 不在本约束判据内（不清、也不该清：那是 I1 的账，且 I1 已 VALIDATE 无此状态）。
  defp clear_deploy_window_stragglers do
    execute("""
    DO $$
    DECLARE
      row_record RECORD;
      affected INTEGER := 0;
      total INTEGER := 0;
    BEGIN
      SELECT count(*) INTO total FROM events WHERE #{@residual_predicate};

      RAISE NOTICE '[#597 check] deploy-window stragglers with residual price_tiers: %', total;

      FOR row_record IN
        SELECT id, price_tiers FROM events WHERE #{@residual_predicate} ORDER BY id
      LOOP
        RAISE NOTICE '[#597 check] event % price_tiers before clear: %',
          row_record.id, row_record.price_tiers;
      END LOOP;

      UPDATE events SET price_tiers = '[]'::jsonb, updated_at = NOW()
       WHERE #{@residual_predicate};

      GET DIAGNOSTICS affected = ROW_COUNT;
      RAISE NOTICE '[#597 check] cleared % straggler row(s)', affected;
    END $$;
    """)
  end

  def down do
    execute "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_deposit_excludes_price_tiers"
  end
end
