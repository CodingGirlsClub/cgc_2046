defmodule Cgc2046.Repo.Migrations.WishReportIdempotency do
  @moduledoc """
  wish2 审计 FIX-4（plan U5）：同人同目标举报幂等——(target_type, target_id,
  reporter_voter_key) 唯一。report/4 域层查重返回既有行；本索引兜底并发窗口
  （IP 频控内双击/并发请求）。

  partial（reporter_voter_key IS NOT NULL）：域层恒写 voter_key（登录 u: /
  匿名 a:），NULL 行不参与唯一性（防脏数据误拦）。
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNIQUE INDEX flashback_reports_unique_target_reporter_index
      ON flashback_reports (target_type, target_id, reporter_voter_key)
      WHERE reporter_voter_key IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS flashback_reports_unique_target_reporter_index")
  end
end
