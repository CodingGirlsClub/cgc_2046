defmodule Cgc2046.Repo.Migrations.AddEventsPaymentModeExclusiveCheck do
  use Ecto.Migration

  # KTD3 并发兜底：Event 缴费三态互斥（免费 / 定价 / 押金）的资源校验是
  # 友好报错层；两个并发编辑/规则传播各基于旧值通过校验时由本 CHECK 拒绝，
  # 由 Event.handle_write_error/2 映射为稳定业务错误
  # events_payment_mode_exclusive。NOT VALID + VALIDATE 两步走避免长表锁
  # （admission_capacity_ledgers_occupancy_nonnegative 同款先例）。
  @disable_ddl_transaction true

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'events_payment_mode_exclusive'
      ) THEN
        ALTER TABLE events
          ADD CONSTRAINT events_payment_mode_exclusive
          CHECK (NOT (deposit_enabled AND pricing_enabled)) NOT VALID;
        ALTER TABLE events
          VALIDATE CONSTRAINT events_payment_mode_exclusive;
      END IF;
    END $$;
    """
  end

  def down do
    execute "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_payment_mode_exclusive"
  end
end
