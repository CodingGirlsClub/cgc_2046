defmodule Cgc2046.Repo.Migrations.AddFlashbackWishFks do
  @moduledoc """
  补建闪念间许愿域 4 条 FK（#724 守卫对齐：DSL `belongs_to` + `references` 已声明，
  手写 migration 漏建约束）：

  - `flashback_wish_endorsements.wish_id` / `flashback_wish_comments.wish_id`
    → `on_delete: :delete`（wish 硬删时级联，与 resource 声明一致）
  - 两表 `person_id` → `on_delete: :nothing`（NO ACTION；person 只软删
    `deleted_at`，不触发硬删，见 Flashback.Deletion）

  两表随本特性分支新建、尚未上线（全环境空表），直接建约束，无需
  NOT VALID / VALIDATE 两段式（活表纪律仅约束已存在的生产增长表）。
  """

  use Ecto.Migration

  def change do
    alter table(:flashback_wish_endorsements) do
      modify :wish_id,
             references(:flashback_wishes, type: :uuid, column: :id, on_delete: :delete_all),
             from: :uuid

      modify :person_id, references(:flashback_people, type: :uuid, column: :id), from: :uuid
    end

    alter table(:flashback_wish_comments) do
      modify :wish_id,
             references(:flashback_wishes, type: :uuid, column: :id, on_delete: :delete_all),
             from: :uuid

      modify :person_id, references(:flashback_people, type: :uuid, column: :id), from: :uuid
    end
  end
end
