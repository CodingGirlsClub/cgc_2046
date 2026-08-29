defmodule Cgc2046.Repo.Migrations.CreateCurriculumCourseRevisions do
  use Ecto.Migration

  @doc """
  role-agent-journeys-v2 S6（R29/R38）：不可变课程版本。

  - `curriculum_course_revisions`：发布即冻结的内容快照（schema v2：goals +
    issues + objectives）；(course_id, number) 唯一且 per-course 单调；
    prep_run_id 溯源教研 run。资源层无 update/destroy action（不可变纪律）。
  - 列/FK/索引与 resource snapshot 20260829112312 一一对应（identity 唯一
    索引 + workspace 查询索引）。

  CONTRIBUTING §4：幂等（create_if_not_exists）+ 可逆（显式 down）。
  """
  def up do
    create_if_not_exists table(:curriculum_course_revisions, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "curriculum_course_revisions_workspace_id_fkey"
          ),
          null: false

      add :course_id,
          references(:courses,
            column: :id,
            type: :uuid,
            name: "curriculum_course_revisions_course_id_fkey"
          ),
          null: false

      add :number, :bigint, null: false
      add :content, :map, null: false

      add :prep_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "curriculum_course_revisions_prep_run_id_fkey"
          )

      add :published_by_id, :uuid
      add :published_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create_if_not_exists unique_index(:curriculum_course_revisions, [:course_id, :number],
                           name: "curriculum_course_revisions_unique_course_number_index"
                         )

    create_if_not_exists index(:curriculum_course_revisions, [:workspace_id],
                           name: "curriculum_course_revisions_workspace_id_index"
                         )
  end

  def down do
    drop_if_exists table(:curriculum_course_revisions)
  end
end
