defmodule Cgc2046.Repo.Migrations.AddCheckInCodeToEnrollments do
  @moduledoc """
  U4/KTD5：Event 报名核销码列与同场唯一索引。

  `(event_id, check_in_code)` 唯一（列序对齐 `identity :unique_check_in_code` 的
  `[:event_id, :check_in_code]` 声明；不带租户列——event_id 唯一决定 workspace_id，
  与 unique_event_user / unique_course_user 同款形状）；`check_in_code IS NOT NULL`
  谓词让 course 报名（码为 NULL）不进索引。该列序让两条消费查询（报名创建避碰预检、
  核销定位，均只带 (event_id, check_in_code) 等值条件）走 Index Only Scan 而非全表扫。
  应用层 `Enrollment.prepare_create` 以同场存在性查询避碰至多 5 次，本索引兜底并发
  窗口，冲突映射为 enrollment_check_in_code_exhausted（可重试业务错误）。

  CONTRIBUTING §4：幂等（*_if_not_exists / *_if_exists 守卫）+ 可逆（显式 down）。
  （文件由 mix ash_postgres.generate_migrations 生成后按仓库纪律手工收口。）
  """

  use Ecto.Migration

  # enrollments 是热表（报名写入路径）：索引用 concurrently 建，避免迁移窗口取
  # SHARE 锁阻塞报名；@disable_ddl_transaction 是 concurrently 的前提（索引建失败
  # 会留 invalid 索引，本迁移可重跑：create_if_not_exists + 下方 down 重建路径）。
  @disable_ddl_transaction true

  def up do
    alter table(:enrollments) do
      add_if_not_exists :check_in_code, :text
    end

    create_if_not_exists unique_index(:enrollments, [:event_id, :check_in_code],
                           name: "enrollments_unique_check_in_code_index",
                           where: "(check_in_code IS NOT NULL)",
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists unique_index(:enrollments, [:event_id, :check_in_code],
                     name: "enrollments_unique_check_in_code_index",
                     concurrently: true
                   )

    alter table(:enrollments) do
      remove_if_exists :check_in_code, :text
    end
  end
end
