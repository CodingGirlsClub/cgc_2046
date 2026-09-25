defmodule Cgc2046.Repo.Migrations.IndexWishAccountAuthors do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    create index(:flashback_wishes, [:user_id, :inserted_at], concurrently: true)

    create unique_index(:flashback_wishes, [:user_id, :request_id],
             name: :flashback_wishes_unique_user_request_index,
             concurrently: true
           )
  end
end
