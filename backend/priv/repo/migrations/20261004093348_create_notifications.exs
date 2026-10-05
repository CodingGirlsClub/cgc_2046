defmodule Cgc2046.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :text, primary_key: true, null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :type, :text, null: false
      add :payload, :map, null: false
      add :deep_link, :text
      add :read_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:notifications, [:user_id, "inserted_at DESC", :id],
             name: :notifications_user_feed_index
           )

    create index(:notifications, [:inserted_at], name: :notifications_retention_index)
  end
end
