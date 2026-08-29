defmodule Cgc2046.Repo.Migrations.CreateLearningAttempts do
  use Ecto.Migration

  @doc """
  role-agent-journeys-v2 S8（ADR-0011 L1）：不可变学习评价账本。

  - `learning_attempts`：一行 = 一次正式评价；锚定三元组
    (learning_run_id, course_revision_id, objective_id)；evidence / rubric_results /
    passed / rationale / confidence / agent_meta；资源层无 update/destroy action
    （失败评价永不删除，重试写新行，R44）。
  - FK ×3：workspace(delete_all) / learning_run(delete_all) /
    course_revision（curriculum_course_revisions）。
  - 索引：三单列 + 复合 [learning_run_id, objective_id, created_at]（掌握投影
    与停滞口径的查询面）。
  - 同 migration drop `learning_records`（L7 退役，幂等 drop_if_exists）。

  CONTRIBUTING §4：幂等（create_if_not_exists / drop_if_exists）+ 可逆（显式 down）。
  """
  def up do
    create_if_not_exists table(:learning_attempts, primary_key: false) do
      add :id, :uuid, default: fragment("gen_random_uuid()"), null: false, primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            type: :uuid,
            name: "learning_attempts_workspace_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :learning_run_id,
          references(:workflow_runs,
            column: :id,
            type: :uuid,
            name: "learning_attempts_learning_run_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :course_revision_id,
          references(:curriculum_course_revisions,
            column: :id,
            type: :uuid,
            name: "learning_attempts_course_revision_id_fkey"
          ),
          null: false

      add :objective_id, :text, null: false
      add :evidence, :text, null: false

      add :rubric_results, {:array, :map},
        default: [],
        null: false

      add :passed, :boolean, null: false
      add :rationale, :text, null: false

      add :confidence, :float, null: false

      add :agent_meta, :map, default: %{}, null: false

      add :created_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create_if_not_exists index(:learning_attempts, [:workspace_id],
                           name: "learning_attempts_workspace_id_index"
                         )

    create_if_not_exists index(:learning_attempts, [:learning_run_id],
                           name: "learning_attempts_learning_run_id_index"
                         )

    create_if_not_exists index(:learning_attempts, [:course_revision_id],
                           name: "learning_attempts_course_revision_id_index"
                         )

    create_if_not_exists index(:learning_attempts, [:learning_run_id, :objective_id, :created_at],
                           name: "learning_attempts_run_objective_created_index"
                         )

    # L7：LearningRecord 表退役（不可变账本取代 latest-only upsert 记忆模型）
    drop_if_exists table(:learning_records)

    drop_if_exists index(:learning_records, [:course_id, :user_id, :issue_id, :item_id],
                     name: "learning_records_unique_course_user_issue_item_index"
                   )
  end

  def down do
    drop_if_exists table(:learning_attempts)
  end
end
