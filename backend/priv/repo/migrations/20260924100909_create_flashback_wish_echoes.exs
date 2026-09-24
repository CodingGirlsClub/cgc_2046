defmodule Cgc2046.Repo.Migrations.CreateFlashbackWishEchoes do
  use Ecto.Migration

  def change do
    create table(:flashback_wish_echoes, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :wish_id,
        references(:flashback_wishes,
          type: :uuid,
          on_delete: :delete_all,
          name: "flashback_wish_echoes_wish_id_fkey"
        ),
        null: false
      )

      add(:content, :text, null: false)
      add(:status, :text, null: false, default: "draft")
      add(:published_at, :utc_datetime_usec)
      add(:corrected_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:published_by_user_id, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:flashback_wish_echoes, [:wish_id, :status, :published_at]))

    create(
      constraint(:flashback_wish_echoes, :flashback_wish_echoes_status_check,
        check: "status IN ('draft', 'published', 'corrected', 'revoked')"
      )
    )

    alter table(:flashback_wish_endorsements) do
      add(:echo_notification_used_at, :utc_datetime_usec)
    end
  end
end
