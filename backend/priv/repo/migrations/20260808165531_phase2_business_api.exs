defmodule Cgc2046.Repo.Migrations.Phase2BusinessApi do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add :enrollment_policy, :text, null: false, default: "open"
      add :capacity, :bigint
      add :confirmed_count, :bigint, null: false, default: 0
      add :registration_deadline, :utc_datetime
    end

    create constraint(:events, :events_capacity_positive,
             check: "capacity IS NULL OR capacity > 0"
           )

    create constraint(:events, :events_confirmed_count_valid,
             check: "confirmed_count >= 0 AND (capacity IS NULL OR confirmed_count <= capacity)"
           )

    alter table(:courses) do
      add :enrollment_policy, :text, null: false, default: "open"
      add :capacity, :bigint
      add :confirmed_count, :bigint, null: false, default: 0
      add :registration_deadline, :utc_datetime
    end

    create constraint(:courses, :courses_capacity_positive,
             check: "capacity IS NULL OR capacity > 0"
           )

    create constraint(:courses, :courses_confirmed_count_valid,
             check: "confirmed_count >= 0 AND (capacity IS NULL OR confirmed_count <= capacity)"
           )

    create table(:invite_batches, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :event_id, references(:events, type: :uuid, on_delete: :delete_all)
      add :course_id, references(:courses, type: :uuid, on_delete: :delete_all)
      add :invite_code, :text, null: false
      add :quota, :bigint, null: false
      add :remaining_quota, :bigint, null: false
      add :expires_at, :utc_datetime
      add :status, :text, null: false, default: "active"
      add :remark, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invite_batches, [:invite_code],
             name: "invite_batches_unique_invite_code_index"
           )

    create constraint(:invite_batches, :invite_batches_exactly_one_target,
             check: "(event_id IS NOT NULL) <> (course_id IS NOT NULL)"
           )

    create constraint(:invite_batches, :invite_batches_quota_valid,
             check: "quota > 0 AND remaining_quota >= 0 AND remaining_quota <= quota"
           )

    create table(:enrollments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces, type: :uuid, on_delete: :delete_all),
          null: false

      add :event_id, references(:events, type: :uuid, on_delete: :delete_all)
      add :course_id, references(:courses, type: :uuid, on_delete: :delete_all)
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :workflow_run_id,
          references(:workflow_runs, type: :uuid, on_delete: :nilify_all)

      add :invite_batch_id,
          references(:invite_batches, type: :uuid, on_delete: :nilify_all)

      add :status, :text, null: false, default: "pending"
      add :submission_payload, :map, null: false, default: %{}
      add :capacity_seq, :bigint

      add :approved_by,
          references(:users, type: :uuid, on_delete: :nilify_all)

      add :approved_at, :utc_datetime
      add :rejection_reason, :text
      add :approval_deadline, :utc_datetime
      add :expired_at, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:enrollments, [:event_id, :user_id],
             name: "enrollments_unique_event_user_index",
             where: "event_id IS NOT NULL AND status IN ('pending', 'confirmed')"
           )

    create unique_index(:enrollments, [:course_id, :user_id],
             name: "enrollments_unique_course_user_index",
             where: "course_id IS NOT NULL AND status IN ('pending', 'confirmed')"
           )

    create index(:enrollments, [:workspace_id, :status, :approval_deadline])

    create constraint(:enrollments, :enrollments_exactly_one_target,
             check: "(event_id IS NOT NULL) <> (course_id IS NOT NULL)"
           )

    create table(:miniprogram_codes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :invitation_id, references(:invitations, type: :uuid, on_delete: :delete_all),
        null: false

      add :platform, :text, null: false
      add :scene, :text, null: false
      add :code, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:miniprogram_codes, [:invitation_id, :platform],
             name: "miniprogram_codes_unique_invitation_platform_index"
           )

    create unique_index(:miniprogram_codes, [:scene],
             name: "miniprogram_codes_unique_scene_index"
           )

    create table(:miniprogram_code_daily_quotas, primary_key: false) do
      add :platform, :text, null: false
      add :quota_date, :date, null: false
      add :used, :bigint, null: false
    end

    create unique_index(:miniprogram_code_daily_quotas, [:platform, :quota_date])

    create table(:mp_notification_consents, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :platform, :text, null: false
      add :template_key, :text, null: false
      add :remaining_uses, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mp_notification_consents, [:user_id, :platform, :template_key],
             name: "mp_notification_consents_unique_user_platform_template_index"
           )

    create constraint(:mp_notification_consents, :mp_notification_consents_non_negative,
             check: "remaining_uses >= 0"
           )
  end

  def down do
    drop table(:mp_notification_consents)
    drop table(:miniprogram_code_daily_quotas)
    drop table(:miniprogram_codes)
    drop table(:enrollments)
    drop table(:invite_batches)

    drop constraint(:courses, :courses_confirmed_count_valid)
    drop constraint(:courses, :courses_capacity_positive)

    alter table(:courses) do
      remove :registration_deadline
      remove :confirmed_count
      remove :capacity
      remove :enrollment_policy
    end

    drop constraint(:events, :events_confirmed_count_valid)
    drop constraint(:events, :events_capacity_positive)

    alter table(:events) do
      remove :registration_deadline
      remove :confirmed_count
      remove :capacity
      remove :enrollment_policy
    end
  end
end
