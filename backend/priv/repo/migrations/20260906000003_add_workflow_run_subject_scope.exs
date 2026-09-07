defmodule Cgc2046.Repo.Migrations.AddWorkflowRunSubjectScope do
  use Ecto.Migration

  def up do
    alter table(:workflow_runs) do
      add_if_not_exists :subject_user_id, :uuid
      add_if_not_exists :subject_course_id, :uuid
      add_if_not_exists :subject_enrollment_id, :uuid
      add_if_not_exists :subject_course_revision_id, :uuid
    end

    create_if_not_exists index(:workflow_runs, [:subject_user_id])
    create_if_not_exists index(:workflow_runs, [:subject_course_id])
    create_if_not_exists index(:workflow_runs, [:subject_enrollment_id])

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM workflow_runs AS r
        JOIN workflow_definitions AS d ON d.id = r.definition_id
        WHERE d.type = 'learning'
          AND (
            (r.input_snapshot ? 'user_id' AND (r.input_snapshot->>'user_id') !~* '^[0-9a-f-]{36}$') OR
            (r.input_snapshot ? 'enrollment_id' AND (r.input_snapshot->>'enrollment_id') !~* '^[0-9a-f-]{36}$') OR
            (r.input_snapshot ? 'course_id' AND (r.input_snapshot->>'course_id') !~* '^[0-9a-f-]{36}$') OR
            (r.input_snapshot ? 'course_revision_id' AND (r.input_snapshot->>'course_revision_id') !~* '^[0-9a-f-]{36}$')
          )
      ) THEN
        RAISE EXCEPTION 'learning workflow run subject preflight found invalid UUID';
      END IF;
    END $$;
    """

    execute """
    UPDATE workflow_runs AS r
    SET subject_user_id = NULLIF(r.input_snapshot->>'user_id', '')::uuid,
        subject_course_id = COALESCE(
          NULLIF(r.input_snapshot->>'course_id', '')::uuid,
          (SELECT e.course_id FROM enrollments AS e
           WHERE e.id = NULLIF(r.input_snapshot->>'enrollment_id', '')::uuid)
        ),
        subject_enrollment_id = COALESCE(
          NULLIF(r.input_snapshot->>'enrollment_id', '')::uuid,
          (SELECT e.id FROM enrollments AS e
           WHERE e.id = NULLIF(r.input_snapshot->>'enrollment_id', '')::uuid)
        ),
        subject_course_revision_id = NULLIF(r.input_snapshot->>'course_revision_id', '')::uuid
    FROM workflow_definitions AS d
    WHERE r.definition_id = d.id
      AND d.type = 'learning'
      AND (r.subject_user_id IS NULL OR r.subject_enrollment_id IS NULL)
      AND (r.input_snapshot->>'user_id') ~* '^[0-9a-f-]{36}$'
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM workflow_runs AS r
        JOIN workflow_definitions AS d ON d.id = r.definition_id
        WHERE d.type = 'learning'
          AND (r.subject_user_id IS NULL OR r.subject_enrollment_id IS NULL)
      ) THEN
        RAISE EXCEPTION 'learning workflow run subject backfill incomplete';
      END IF;
    END $$;
    """
  end

  def down do
    drop_if_exists index(:workflow_runs, [:subject_user_id])
    drop_if_exists index(:workflow_runs, [:subject_course_id])
    drop_if_exists index(:workflow_runs, [:subject_enrollment_id])

    alter table(:workflow_runs) do
      remove_if_exists :subject_user_id, :uuid
      remove_if_exists :subject_course_id, :uuid
      remove_if_exists :subject_enrollment_id, :uuid
      remove_if_exists :subject_course_revision_id, :uuid
    end
  end
end
