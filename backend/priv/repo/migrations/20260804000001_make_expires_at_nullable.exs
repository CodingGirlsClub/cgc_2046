defmodule Cgc2046.Repo.Migrations.MakeExpiresAtNullable do
  use Ecto.Migration

  def up do
    alter table(:invitations) do
      modify :expires_at, :utc_datetime, null: true
    end
  end

  def down do
    alter table(:invitations) do
      modify :expires_at, :utc_datetime, null: false
    end
  end
end
