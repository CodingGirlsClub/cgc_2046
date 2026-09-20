defmodule Cgc2046.Repo.Migrations.CreateRecruitmentTables do
  use Ecto.Migration

  # 志愿者招募三表（R8/R9；KTD2）。手写 migration 路线（范式
  # 20260913155651_create_initiatives_and_moderators.exs）：索引名与 identity
  # 推导名逐字一致（IndexCatalog 公式 `<table>_<identity>_index`），
  # 否则 unique_constraint(match: :exact) 接不住、错误落 database_error（#611）。
  def change do
    create table(:recruitment_cohorts, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :workspace_id,
        references(:workspaces, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:name, :text, null: false)
      add(:apply_deadline_at, :utc_datetime, null: false)
      add(:starts_at, :utc_datetime)
      add(:ends_at, :utc_datetime)
      add(:status, :text, null: false, default: "draft")
      timestamps(type: :utc_datetime_usec)
    end

    # 不变量「同一 workspace 至多一个 open」（R8/AE9）：部分唯一索引由 DB 承担，
    # 并发安全；identity `unique_open_per_workspace`（where status = 'open'）只声明语义
    create(
      unique_index(:recruitment_cohorts, [:workspace_id],
        where: "status = 'open'",
        name: "recruitment_cohorts_unique_open_per_workspace_index"
      )
    )

    create(index(:recruitment_cohorts, [:status]))

    create table(:resume_profiles, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :workspace_id,
        references(:workspaces, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:full_name, :text, null: false)
      add(:contact_email, :text, null: false)
      add(:weekly_hours, :bigint)
      add(:skills, {:array, :text}, null: false, default: [])

      # 简历文件（KTD3 最小上传管道）：内容 bytea + 元数据同表；写入在 U2
      add(:file_name, :text)
      add(:file_content_type, :text)
      add(:file_size, :bigint)
      add(:uploaded_at, :utc_datetime)
      add(:file_data, :binary)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:resume_profiles, [:workspace_id, :user_id],
        name: "resume_profiles_one_per_workspace_user_index"
      )
    )

    create(index(:resume_profiles, [:user_id]))

    create table(:volunteer_applications, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :workspace_id,
        references(:workspaces, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(
        :cohort_id,
        references(:recruitment_cohorts, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:position, :text, null: false)
      add(:city, :text)
      add(:heard_about_us, :text)
      add(:has_internal_referrer, :boolean, null: false, default: false)
      add(:message, :text)
      add(:status, :text, null: false, default: "submitted")
      add(:rejection_reason, :text)

      add(
        :assigned_event_id,
        references(:events, type: :uuid, column: :id, on_delete: :nilify_all)
      )

      add(:assignment_note, :text)
      add(:assigned_at, :utc_datetime)
      timestamps(type: :utc_datetime_usec)
    end

    # 同批一份（AE2）：换职位不重置（职位不在键内）
    create(
      unique_index(:volunteer_applications, [:user_id, :cohort_id],
        name: "volunteer_applications_unique_per_cohort_index"
      )
    )

    # 管理面检索（R13：按批次/职位查看列表）
    create(index(:volunteer_applications, [:workspace_id, :cohort_id, :position]))
    create(index(:volunteer_applications, [:workspace_id, :status]))
  end
end
