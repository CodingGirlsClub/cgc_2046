defmodule Cgc2046.Repo.Migrations.DropStepAgentIdAndPlatformOps do
  @moduledoc """
  R2/R3 漂移裁决落地（DRIFT-REPORT §7.1，2026-08-16）：

  - R2：workflow_steps.agent_id 删除——形态 X（BYO，ADR-0001）下平台不建模
    Agent 实体，该列自创建起即为无消费方的悬空引用（领域模型图的 Agent/
    AgentRole/AgentRun 三实体从未落地）。
  - R3：WorkflowDefinition.type 删 platform_ops 枚举值（Ash one_of 应用层
    已同步收紧）——全库零驱动代码的死枚举。DB 侧清理同型数据行
    （仅测试 fixture 可能产生，先删 steps 再删 definitions 满足 FK）。
  """

  use Ecto.Migration

  def up do
    # R2：删悬空列
    alter table(:workflow_steps) do
      remove :agent_id
    end

    # R3：清 platform_ops 数据（无人认领；steps 经 FK 先行）
    execute """
            DELETE FROM workflow_steps
            WHERE definition_id IN (
              SELECT id FROM workflow_definitions WHERE type = 'platform_ops'
            )
            """,
            ""

    execute """
            DELETE FROM workflow_definitions WHERE type = 'platform_ops'
            """,
            ""
  end

  def down do
    alter table(:workflow_steps) do
      add :agent_id, :uuid
    end

    # platform_ops 数据不可恢复（R3 裁决为删除）
  end
end
