defmodule Cgc2046.Repo.Migrations.AddT08WorkflowStepStatus do
  @moduledoc """
  T08(T09):Workflow / Step 状态字段。

  - workflows.status: 草稿 → 发布 → 归档(draft/published/archived),默认 published
    (DSL 部署即发布;T05 既有创建行为保持可执行)。
  - steps.status: 待执行 → 进行中 → 完成(pending/in_progress/completed),默认 pending。
  """

  use Ecto.Migration

  def up do
    alter table(:workflows) do
      add :status, :text, null: false, default: "published"
    end

    alter table(:steps) do
      add :status, :text, null: false, default: "pending"
    end
  end

  def down do
    alter table(:steps) do
      remove :status
    end

    alter table(:workflows) do
      remove :status
    end
  end
end
