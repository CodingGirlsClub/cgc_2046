defmodule Cgc2046.Repo.Migrations.CreateInitiativesAndModerators do
  use Ecto.Migration

  def change do
    create table(:initiatives, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :text, null: false)
      add(:slug, :string, null: false)
      add(:hashtag, :string)
      add(:description, :text)
      add(:window_starts_at, :utc_datetime)
      add(:window_ends_at, :utc_datetime)
      add(:status, :string, null: false, default: "draft")
      add(:created_by, references(:users, type: :uuid, column: :id, on_delete: :nilify_all))
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:initiatives, [:slug]))
    create(index(:initiatives, [:status]))

    create table(:initiative_rules, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :initiative_id,
        references(:initiatives, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:key, :string, null: false)
      add(:value, :map, null: false, default: %{})
      add(:locked, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:initiative_rules, [:initiative_id, :key]))
    create(index(:initiative_rules, [:initiative_id]))

    alter table(:events) do
      add(:created_by, references(:users, type: :uuid, column: :id, on_delete: :nilify_all))

      add(
        :initiative_id,
        references(:initiatives, type: :uuid, column: :id, on_delete: :nilify_all)
      )

      add(:deposit_enabled, :boolean, null: false, default: false)
      add(:deposit_amount_cents, :bigint)
      add(:min_age, :integer)
      add(:min_participants, :integer)
      add(:qualification_status, :string, null: false, default: "pending")
    end

    create(index(:events, [:initiative_id]))
    create(index(:events, [:initiative_id, :status, :visibility]))

    create table(:event_moderators, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :workspace_id,
        references(:workspaces, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:event_id, references(:events, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, column: :id, on_delete: :delete_all),
        null: false
      )

      add(:assigned_by, references(:users, type: :uuid, column: :id, on_delete: :nilify_all))

      add(:assigned_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() at time zone 'utc')")
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:event_moderators, [:event_id, :user_id]))
    create(index(:event_moderators, [:workspace_id, :event_id]))
    create(index(:event_moderators, [:user_id]))
  end
end
