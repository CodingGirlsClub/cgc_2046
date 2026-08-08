defmodule Cgc2046.Repo.Migrations.DropUserProfileColumns do
  @moduledoc """
  ADR-0004（Phase 5）：删除 users 表已迁出的 profile 字段。

  profile 字段（avatar_url/location/about/skills/visibility/ui_theme_preference）
  已迁至 workspace_profiles（per-workspace，见 20260808000000_create_workspace_profiles），
  users 仅保留全局身份（email/display_name/is_platform_admin）。

  down：恢复列（默认值与资源定义一致：skills default []、visibility default only_me、
  ui_theme_preference default dark）。数据不可恢复（已迁出），down 仅恢复结构。
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      remove :avatar_url
      remove :location
      remove :about
      remove :skills
      remove :visibility
      remove :ui_theme_preference
    end
  end

  def down do
    alter table(:users) do
      add :avatar_url, :text
      add :location, :text
      add :about, :text
      add :skills, {:array, :text}, default: []
      add :visibility, :text, null: false, default: "only_me"
      add :ui_theme_preference, :string, null: false, default: "dark"
    end
  end
end
