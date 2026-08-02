defmodule Cgc2046.Repo.Migrations.BackfillDesignRoles do
  @moduledoc """
  G1：为存量 workspace 幂等补齐设计稿角色 tutor / volunteer / learner。

  #64 阶段 workspace 创建时只 seed owner/admin/member 三角色；
  G1 将默认角色模板扩展为六角色（owner/admin/member/tutor/volunteer/learner）。
  本迁移为**已有** workspace 补齐缺失的设计角色（name 冲突时跳过，幂等），
  新 workspace 由 `Workspace.create` after_action 直接 seed 六角色，无需处理。

  roles.name 为 text，唯一约束 (workspace_id, name) → `ON CONFLICT (workspace_id, name) DO NOTHING`。

  ## gen_random_uuid 说明（Standards #10 误报留档）

  本迁移 `INSERT ... SELECT gen_random_uuid()` 使用的是 PG 13+ **核心函数**，
  不依赖 pgcrypto 扩展；仓库 `Cgc2046.Repo` 声明 `min_pg_version: 16`，
  新环境必然可用，请勿加 `CREATE EXTENSION pgcrypto`（PG 13+ 安装反而可能
  产生同名函数歧义）。全迁移链（uuid 列默认值、`uuid_generate_v7()`）同依赖此函数。

  ## 单源提示（G2 收敛）

  角色枚举唯一真源是 `Cgc2046.Accounts.Role.role_names/0`（六角色 owner/admin/member/tutor/volunteer/learner）。
  本迁移为**历史迁移**，仅含 G1 新增的设计角色子集（tutor/volunteer/learner），
  保持不动以免破坏已执行的迁移历史；新增/修改角色请一律改 Role 模块。
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
