defmodule Cgc2046.Repo.Migrations.AddSlugAndDescriptionToOfferings do
  @moduledoc """
  E-5 #50：Event/Course 公开宿主页 slug 与描述字段。

  - slug：公开 URL 段（/events/[slug]、/courses/[slug]），全局唯一（公开路由
    无 workspace 前缀）；存量行回填 `e-/c-` + id 前 8 位（创建者随后可改）。
  - description：公开展示文案，可空。
  """

  use Ecto.Migration

  def up do
    alter table(:events) do
      add :slug, :string
      add :description, :text
    end

    alter table(:courses) do
      add :slug, :string
      add :description, :text
    end

    execute("UPDATE events SET slug = 'e-' || replace(id::text, '-', '') WHERE slug IS NULL")

    execute("UPDATE courses SET slug = 'c-' || replace(id::text, '-', '') WHERE slug IS NULL")

    alter table(:events) do
      modify :slug, :string, null: false
      modify :description, :text, null: true, default: nil
    end

    alter table(:courses) do
      modify :slug, :string, null: false
      modify :description, :text, null: true, default: nil
    end

    create unique_index(:events, [:slug])
    create unique_index(:courses, [:slug])
  end

  def down do
    drop unique_index(:courses, [:slug])
    drop unique_index(:events, [:slug])

    alter table(:events) do
      remove :description
      remove :slug
    end

    alter table(:courses) do
      remove :description
      remove :slug
    end
  end
end
