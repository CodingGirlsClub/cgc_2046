defmodule Cgc2046.Repo.Migrations.AddScheduleAndVenueToOfferings do
  use Ecto.Migration

  # CONTRIBUTING §4：幂等（*_if_not_exists / *_if_exists 守卫）+ 可逆（显式 down）
  def up do
    alter table(:events) do
      add_if_not_exists :starts_at, :utc_datetime
      add_if_not_exists :ends_at, :utc_datetime
      add_if_not_exists :venue, :map
    end

    alter table(:courses) do
      add_if_not_exists :starts_at, :utc_datetime
      add_if_not_exists :ends_at, :utc_datetime
    end
  end

  def down do
    alter table(:events) do
      remove_if_exists :venue, :map
      remove_if_exists :ends_at, :utc_datetime
      remove_if_exists :starts_at, :utc_datetime
    end

    alter table(:courses) do
      remove_if_exists :ends_at, :utc_datetime
      remove_if_exists :starts_at, :utc_datetime
    end
  end
end
