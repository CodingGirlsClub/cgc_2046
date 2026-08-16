defmodule Cgc2046.Repo.Migrations.CreateResearchOutputs do
  @moduledoc """
  课程 issue 学习闭环 U1(切片 H, #180):教研产出的持久层。

  `research_outputs` 表:`(key, kind)` 唯一(活文档按 key 更新,见
  ResearchOutput.upsert_content);v1 `kind = "issues"` 承载 course content
  JSONB(goals + issue 卡集,形状校验在资源 changeset 层)。
  """

  use Ecto.Migration

  def up do
    create table(:research_outputs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "research_outputs_workspace_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      # key = "course_<id>"(CourseContent key 约定);course id 全局唯一 →
      # (key, kind) 全局唯一,重复即 bug
      add :key, :text, null: false
      # v1 仅 "issues";":materials"/":archive" 后置(设计 §4.1)
      add :kind, :text, null: false
      add :data, :map, null: false
      add :submitted_by, :uuid, null: false
      add :workflow_run_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:research_outputs, [:key, :kind],
             name: "research_outputs_unique_key_kind_index"
           )

    create index(:research_outputs, [:workspace_id])
  end

  def down do
    drop table(:research_outputs)
  end
end
