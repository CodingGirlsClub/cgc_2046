defmodule Cgc2046.Repo.Migrations.ValidateWishAccountAuthors do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE flashback_wishes VALIDATE CONSTRAINT flashback_wishes_user_id_fkey"
    execute "ALTER TABLE flashback_wishes VALIDATE CONSTRAINT flashback_wishes_author_required"
  end

  def down, do: :ok
end
