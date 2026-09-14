defmodule Cgc2046.Repo.Migrations.AddCheckInCodeToEnrollments do
  @moduledoc """
  U4/KTD5：Event 报名核销码列与同场唯一索引。

  `(workspace_id, event_id, check_in_code)` 唯一（tenant 列随多租户惯例入索引，
  与 unique_event_user / unique_course_user 同款形状）；`check_in_code IS NOT NULL`
  谓词让 course 报名（码为 NULL）不进索引。应用层 `Enrollment.prepare_create`
  以同场存在性查询避碰至多 5 次，本索引兜底并发窗口，冲突映射为
  enrollment_check_in_code_exhausted（可重试业务错误）。

  CONTRIBUTING §4：幂等（*_if_not_exists / *_if_exists 守卫）+ 可逆（显式 down）。
  （文件由 mix ash_postgres.generate_migrations 生成后按仓库纪律手工收口。）
  """

  use Ecto.Migration

  def up do
    alter table(:enrollments) do
      add_if_not_exists :check_in_code, :text
    end

    create_if_not_exists unique_index(:enrollments, [:workspace_id, :event_id, :check_in_code],
                           name: "enrollments_unique_check_in_code_index",
                           where: "(check_in_code IS NOT NULL)"
                         )
  end

  def down do
    drop_if_exists unique_index(:enrollments, [:workspace_id, :event_id, :check_in_code],
                     name: "enrollments_unique_check_in_code_index"
                   )

    alter table(:enrollments) do
      remove_if_exists :check_in_code, :text
    end
  end
end
