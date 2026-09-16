defmodule Cgc2046.Repo.Migrations.CompleteInitiativeBoundaries do
  use Ecto.Migration

  def change do
    alter table(:notification_deliveries) do
      add :idempotency_key, :text
    end

    execute "UPDATE notification_deliveries SET idempotency_key = id::text", "SELECT 1"

    alter table(:notification_deliveries) do
      modify :idempotency_key, :text, null: false, from: {:text, null: true}
    end

    create unique_index(:notification_deliveries, [:idempotency_key],
             name: :notification_deliveries_unique_delivery_index
           )

    alter table(:enrollments) do
      add :age_confirmed_at, :utc_datetime
      add :terms_version, :text
    end
  end
end
