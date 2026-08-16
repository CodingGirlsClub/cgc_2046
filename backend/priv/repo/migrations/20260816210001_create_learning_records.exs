defmodule Cgc2046.Repo.Migrations.CreateLearningRecords do
  @moduledoc """
  课程 issue 学习闭环 U2(切片 H, #180):个人学习记忆库。

  `learning_records` 表:唯一键 `(course_id, user_id, issue_id, item_id)`
  upsert 最新为准(记忆挂人不挂报名——enrollment_id/run_id 是审计列,不参与
  唯一性);done/evidence/recorded_at;issue_id/item_id 字符串宽存(无内容
  外键,KTD4 id 稳定纪律)。
  """

  use Ecto.Migration

  def up do
    create table(:learning_records, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "learning_records_workspace_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      # 记忆归属锚:course + user(挂人不挂报名)
      add :course_id,
          references(:courses,
            column: :id,
            name: "learning_records_course_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :user_id, :uuid, null: false

      # 宽存字符串引用(R2/KTD4:id 稳定纪律,内容编辑不破坏记录)
      add :issue_id, :text, null: false
      add :item_id, :text, null: false

      add :done, :boolean, null: false, default: false
      add :evidence, :text
      add :recorded_at, :utc_datetime_usec, null: false

      # 审计列:记录当时哪个报名/哪个 run 写的(不参与唯一性)
      add :enrollment_id, :uuid
      add :run_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    # 记忆唯一键:同一人同一课程同一 issue 同一条目一行(全局——course_id 全局
    # 唯一,记忆挂人不挂报名跨 enrollment 延续)
    create unique_index(:learning_records, [:course_id, :user_id, :issue_id, :item_id],
             name: "learning_records_unique_key_index"
           )

    create index(:learning_records, [:workspace_id])
    create index(:learning_records, [:user_id])
  end

  def down do
    drop table(:learning_records)
  end
end
