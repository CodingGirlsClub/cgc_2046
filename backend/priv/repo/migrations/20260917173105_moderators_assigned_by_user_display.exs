defmodule Cgc2046.Repo.Migrations.ModeratorsAssignedByUserDisplay do
  @moduledoc """
  #537：event_moderators.assigned_by 的 FK 进入 ash_postgres snapshot 链。

  `belongs_to(:assigned_by_user)`（回显平铺 calculation 的 JOIN 路径）使资源
  snapshot 与代码期望出现漂移，CI `--check` 门禁红（PR #721）。DB 侧该 FK
  自 20260913155651 手写建表起即存在且为 SET NULL（用户删除 → 指派人置空、
  主理人行保留）——本迁移不引入新约束语义，只做同形重建对齐（drop + 按契约重建），并把 resource 侧 `references(:assigned_by_user,
  on_delete: :nilify)` 与 snapshot 记录三方对齐。

  注意：ash 自动生成版本为 NO ACTION（撞名 duplicate_object，且属行为回退），
  已手改；与本表 user_id 列的既有形态一致（FK 均由手写 migration 承载）。
  """

  use Ecto.Migration

  @fk "event_moderators_assigned_by_fkey"

  def up do
    # 建表链（baseline → 20260913155651）恒建此约束，drop 不存在则失败即暴露环境异常（fail-closed）
    drop(constraint(:event_moderators, @fk))

    alter table(:event_moderators) do
      modify(
        :assigned_by,
        references(:users,
          column: :id,
          name: @fk,
          type: :uuid,
          prefix: "public",
          on_delete: :nilify_all
        )
      )
    end
  end

  def down do
    drop(constraint(:event_moderators, @fk))

    alter table(:event_moderators) do
      modify(:assigned_by, :uuid)
    end
  end
end
