defmodule Cgc2046.Repo.Migrations.CreateAttendances do
  @moduledoc """
  U5/KTD4：到场事实表（核销账本）。

  - 一行 = 一次核销：`workspace_id` / `enrollment_id` / `event_id` / `operator_id` /
    `checked_in_at` / `method`（scan / manual）。
  - `attendances_unique_enrollment_index`（**仅 enrollment_id**，identity
    `all_tenants? true`）：核销幂等的唯一承载——同一报名的第二次核销在 DB 层被拒，
    映射为业务错误 `attendance_already_checked_in`（先例
    `payments_orders_unique_active_order_index`）。索引不拼租户列：报名天然只属于
    一个 workspace，跨租户同 enrollment 的第二行同属违规。
  - FK ×3（enrollments / events / users，`operator_id` 为核销人）沿资源声明默认
    （无 ON DELETE 动作，与 enrollments / payments_orders 同款）。

  CONTRIBUTING §4：幂等（*_if_not_exists）+ 可逆（显式 down）。
  （文件由 mix ash_postgres.generate_migrations 生成后按仓库纪律手工收口。）
  """

  use Ecto.Migration

  def up do
    create_if_not_exists table(:attendances, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :workspace_id, :uuid, null: false

      add :enrollment_id,
          references(:enrollments,
            column: :id,
            name: "attendances_enrollment_id_fkey",
            type: :uuid
          ),
          null: false

      add :event_id,
          references(:events,
            column: :id,
            name: "attendances_event_id_fkey",
            type: :uuid
          ),
          null: false

      add :operator_id,
          references(:users,
            column: :id,
            name: "attendances_operator_id_fkey",
            type: :uuid
          ),
          null: false

      add :checked_in_at, :utc_datetime, null: false
      add :method, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create_if_not_exists unique_index(:attendances, [:enrollment_id],
                           name: "attendances_unique_enrollment_index"
                         )
  end

  def down do
    # 索引与 FK 随表删除，无需单独 drop（learning_attempts 同款显式 down）
    drop_if_exists table(:attendances)
  end
end
