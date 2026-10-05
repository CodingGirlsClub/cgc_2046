defmodule Cgc2046.Repo.Migrations.IndexNotificationDeliverySources do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(
             :notification_deliveries,
             [:user_id, :template_key, "jsonb_extract_path_text(job_meta, 'idempotency_key')"],
             name: :notification_deliveries_source_index,
             concurrently: true
           )
  end
end
