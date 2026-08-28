defmodule Cgc2046.Repo.Migrations.AddOccupancyNonnegativeCheck do
  @moduledoc """
  Fable 5 评审 LOW:名额账本 occupancy 负数防御。

  占位/释放全靠条件 UPDATE 的 WHERE 守卫(occupancy < capacity 占、
  occupancy > 0 放),正常路径不会为负;CHECK 把「守卫失效」从静默腐蚀
  升级为事务级报错,与 R12 账本不变量对齐。幂等(DO 块查 pg_constraint)
  且可逆。
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'admission_capacity_ledgers_occupancy_nonnegative'
      ) THEN
        ALTER TABLE admission_capacity_ledgers
          ADD CONSTRAINT admission_capacity_ledgers_occupancy_nonnegative
          CHECK (occupancy >= 0) NOT VALID;
        ALTER TABLE admission_capacity_ledgers
          VALIDATE CONSTRAINT admission_capacity_ledgers_occupancy_nonnegative;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    ALTER TABLE admission_capacity_ledgers
      DROP CONSTRAINT IF EXISTS admission_capacity_ledgers_occupancy_nonnegative
    """)
  end
end
