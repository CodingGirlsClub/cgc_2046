defmodule Cgc2046.Repo.Migrations.AddFlashbackPersonDeletedAt do
  use Ecto.Migration

  def change do
    alter table(:flashback_people) do
      add :deleted_at, :utc_datetime_usec
    end
  end
end
