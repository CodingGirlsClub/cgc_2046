defmodule Cgc2046.Repo.Migrations.DropJidoCheckpointAndThreadTables do
  use Ecto.Migration

  def up do
    drop_if_exists table(:jido_thread_meta)
    drop_if_exists table(:jido_thread_entries)
    drop_if_exists table(:jido_checkpoints)
  end

  def down do
    create table(:jido_checkpoints, primary_key: false) do
      add :key_bytea, :binary, null: false, primary_key: true
      add :data_bytea, :binary, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false

      add :updated_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:jido_thread_entries, primary_key: false) do
      add :thread_id, :string, size: 255, null: false, primary_key: true
      add :seq, :bigint, null: false, primary_key: true
      add :entry_bytea, :binary, null: false

      add :inserted_at, :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')"),
        null: false
    end

    create table(:jido_thread_meta, primary_key: false) do
      add :thread_id, :string, size: 255, null: false, primary_key: true
      add :rev, :bigint, default: 0, null: false
      add :metadata_bytea, :binary
      add :created_at, :bigint
      add :updated_at, :bigint
    end
  end
end
