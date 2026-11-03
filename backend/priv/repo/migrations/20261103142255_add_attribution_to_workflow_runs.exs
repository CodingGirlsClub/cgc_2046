defmodule Cgc2046.Repo.Migrations.AddAttributionToWorkflowRuns do
  @moduledoc """
  #1128 裁决 D2（最小归因）：workflow_runs 记录创建原因 / 触发人 / 上一周期。

  - `created_reason`：`course_created`（course.created 信号的首周期）/ `next_cycle`
    （发布后首次读取懒开的次周期）
  - `created_by_actor_id`：次周期触发人；首周期事件载荷无 actor，落 nil
  - `previous_run_id`：上一周期 run id；首周期 nil。**刻意不建 FK**：审计链接，
    避免 live 表 FK 校验与 fk guard 新增面

  三列均可空、无默认、无索引：仅新建的 run 写入，存量行为 nil（= 未知来源），
  不回填。ADD COLUMN 在 PostgreSQL ≥11 为 catalog-only，不需 `@disable_ddl_transaction`。
  """
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add(:created_reason, :text)
      add(:created_by_actor_id, :uuid)
      add(:previous_run_id, :uuid)
    end
  end
end
