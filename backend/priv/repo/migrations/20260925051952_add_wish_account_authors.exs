defmodule Cgc2046.Repo.Migrations.AddWishAccountAuthors do
  use Ecto.Migration

  def up do
    # Existing person_id NOT NULL proves the owner check for all historical rows.
    alter table(:flashback_wishes) do
      modify :person_id, :uuid, null: true
      add :user_id, :uuid
      add :request_id, :text
      add :request_fingerprint, :text
    end

    execute "ALTER TABLE flashback_wishes ADD CONSTRAINT flashback_wishes_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE NOT VALID"

    execute "ALTER TABLE flashback_wishes ADD CONSTRAINT flashback_wishes_author_required CHECK (person_id IS NOT NULL OR user_id IS NOT NULL) NOT VALID"
  end

  def down do
    # Refuse destructive rollback once account-only authors exist; roll forward instead.
    execute "ALTER TABLE flashback_wishes ALTER COLUMN person_id SET NOT NULL"
    execute "ALTER TABLE flashback_wishes DROP CONSTRAINT flashback_wishes_author_required"

    alter table(:flashback_wishes) do
      remove :request_fingerprint
      remove :request_id
      remove :user_id
    end
  end
end
