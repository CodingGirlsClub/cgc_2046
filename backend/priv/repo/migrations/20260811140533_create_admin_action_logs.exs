defmodule Cgc2046.Repo.Migrations.CreateAdminActionLogs do
  @moduledoc """
  Creates admin_action_logs table for AdminActionLog resource
  （#116 R10a：admin 治理操作留痕，区别于 Mcp.ToolCallLog 运营审计）。

  全局资源（无 workspace_id——治理操作跨工作台/用户）。只增不改的日志表，
  无 updated_at（create_timestamp only）。

  顺带（#116 决策 6 对称字段）：workspace_applications 补 rejected_by/rejected_at，
  与既有 approved_by/approved_at 对称，供审批队列展示「谁处理的」。
  """

  use Ecto.Migration

  def change do
    create table(:admin_action_logs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      # nil = 系统/CLI（无 actor 调用，如 CLI task 直调 set_platform_admin）
      add :actor_id, :uuid
      add :action, :text, null: false
      add :target_type, :text, null: false
      add :target_id, :uuid, null: false
      add :result, :text, null: false, default: "success"
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    # 按目标反查（治理操作审计的主查询维度）与按动作类型过滤（admin list action 参数）
    create index(:admin_action_logs, [:target_type, :target_id])
    create index(:admin_action_logs, [:action])

    alter table(:workspace_applications) do
      add :rejected_by, :uuid
      add :rejected_at, :utc_datetime
    end
  end
end
