defmodule Cgc2046.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  def change do
    create table(:notification_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :platform, :text, null: false
      add :identity_uid, :text, null: false
      add :template_key, :text, null: false
      add :data, :map, null: false, default: %{}
      add :job_meta, :map, null: false, default: %{}
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:notification_deliveries, [:status, :inserted_at])
  end
end
