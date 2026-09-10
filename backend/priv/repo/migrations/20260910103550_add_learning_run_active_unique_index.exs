defmodule Cgc2046.Repo.Migrations.AddLearningRunActiveUniqueIndex do
  @moduledoc """
  issue #505 D8 去重闸：学习 run 在（workspace × subject_user ×
  subject_course_revision）维度上**非终态唯一**（partial unique index）。

  背景：报名完成信号路径（LearningInstantiator）与 OpenClacky
  start_learning_run 工具路径（Runs.start/3）并发双种，或活动/课程
  双通道报名汇入，都会在没有 DB 闸的情况下种出重复 run。应用层
  `Runs.non_terminal_run/3` 预查 + 本索引兜底：撞索引方回读转 :existing。

  维度语义：一个学员对一个课程版本同一时刻只有一个活跃学习 run；
  终态（succeeded/failed/cancelled/expired）后允许重新实例化（重学）。

  `subject_course_revision_id IS NOT NULL` 即学习 run 标记（curriculum
  run 的 input 不带 course_revision_id，不镜像该列）。
  """
  use Ecto.Migration

  @index :workflow_runs_learning_active_user_revision_index

  def up do
    # 存量冲突 preflight：同一 (workspace, user, revision) 已有多个非终态
    # learning run 时建索引必炸——先显式报错，由对账清理后重跑。
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM workflow_runs
        WHERE subject_course_revision_id IS NOT NULL
          AND status IN ('pending', 'running', 'waiting')
        GROUP BY workspace_id, subject_user_id, subject_course_revision_id
        HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'learning run active uniqueness preflight failed: duplicate non-terminal runs exist for the same (workspace, user, revision)';
      END IF;
    END $$;
    """

    create_if_not_exists unique_index(
                           :workflow_runs,
                           [:workspace_id, :subject_user_id, :subject_course_revision_id],
                           name: @index,
                           where:
                             "subject_course_revision_id IS NOT NULL AND status IN ('pending', 'running', 'waiting')"
                         )
  end

  def down do
    drop_if_exists index(
                     :workflow_runs,
                     [:workspace_id, :subject_user_id, :subject_course_revision_id],
                     name: @index
                   )
  end
end
