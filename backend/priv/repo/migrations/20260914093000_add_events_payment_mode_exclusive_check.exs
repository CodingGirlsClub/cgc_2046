defmodule Cgc2046.Repo.Migrations.AddEventsPaymentModeExclusiveCheck do
  use Ecto.Migration

  # KTD3 并发兜底：Event 缴费三态互斥（免费 / 定价 / 押金）的资源校验是
  # 友好报错层；两个并发编辑/规则传播各基于旧值通过校验时由本 CHECK 拒绝，
  # 由 Event.handle_write_error/2 映射为稳定业务错误 events_payment_mode_exclusive。
  #
  # 两步拆成**独立语句**（@disable_ddl_transaction → 各自事务）：ADD ... NOT VALID
  # 只取短暂 ACCESS EXCLUSIVE 并立即释放，VALIDATE 仅取 SHARE UPDATE EXCLUSIVE
  # 且不阻塞读写。若把 ADD 与 VALIDATE 放进同一个 DO 块，两者同事务 → ADD 的
  # ACCESS EXCLUSIVE 会一直持到 VALIDATE 全表扫描结束，且存量违规行会让整个
  # 迁移回滚（NOT VALID 的容忍度形同虚设）。
  @disable_ddl_transaction true

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'events_payment_mode_exclusive' AND conrelid = 'events'::regclass
      ) THEN
        ALTER TABLE events
          ADD CONSTRAINT events_payment_mode_exclusive
          CHECK (NOT (deposit_enabled AND pricing_enabled)) NOT VALID;
      END IF;
    END $$;
    """

    # 幂等：已 VALIDATE 的约束重复 VALIDATE 是空操作
    execute "ALTER TABLE events VALIDATE CONSTRAINT events_payment_mode_exclusive"
  end

  def down do
    execute "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_payment_mode_exclusive"
  end
end
