defmodule Cgc2046.Repo.Migrations.BackfillDesignRoles do
  @moduledoc """
  G1：为存量 workspace 幂等补齐设计稿角色 tutor / volunteer / learner。

  #64 阶段 workspace 创建时只 seed owner/admin/member 三角色；
  G1 将默认角色模板扩展为六角色（owner/admin/member/tutor/volunteer/learner）。
  本迁移为**已有** workspace 补齐缺失的设计角色（name 冲突时跳过，幂等），
  新 workspace 由 `Workspace.create` after_action 直接 seed 六角色，无需处理。

  roles.name 为 text，唯一约束 (workspace_id, name) → `ON CONFLICT (workspace_id, name) DO NOTHING`。
  """

  use Ecto.Migration

  @design_roles [
    {"tutor", "讲师：内容与教学支持"},
    {"volunteer", "志愿者：活动与运营支持"},
    {"learner", "学员：学习与参与"}
  ]

  def up do
    execute fn ->
      for {name, description} <- @design_roles do
        Ecto.Adapters.SQL.query!(
          repo(),
          """
          INSERT INTO roles (id, workspace_id, name, description, inserted_at, updated_at)
          SELECT gen_random_uuid(), w.id, $1, $2, now(), now()
          FROM workspaces w
          ON CONFLICT (workspace_id, name) DO NOTHING
          """,
          [name, description]
        )
      end
    end
  end

  def down do
    # 回滚：删除设计稿角色（仅删没有成员引用且属设计角色的记录；若有成员已使用，保留避免破坏外键）
    execute fn ->
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        DELETE FROM roles r
        USING workspaces w
        WHERE r.workspace_id = w.id
          AND r.name IN ('tutor', 'volunteer', 'learner')
          AND NOT EXISTS (
            SELECT 1 FROM membership_roles mr WHERE mr.role_id = r.id
          )
        """
      )
    end
  end
end
