defmodule Cgc2046.Repo.Migrations.AddVisibilityToEventsAndCourses do
  @moduledoc """
  E-11 #127：Event/Course 可见性轴（visibility: public | workspace）。

  纯加列 + 默认值，无既有数据变更；回滚 = drop column 一步。
  """

  use Ecto.Migration

  def change do
    alter table(:events) do
      add :visibility, :string, null: false, default: "public"
    end

    alter table(:courses) do
      add :visibility, :string, null: false, default: "public"
    end
  end
end
