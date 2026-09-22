defmodule Cgc2046.Repo.Migrations.AddU1WishPublicListing do
  @moduledoc """
  U1（KTD1 + KTD11）：flashback_wishes 加 signature/listed_at/hidden_at，
  存量 signature = masked_name(person) 快照，存量 listed_at = NULL，
  存量 hidden_at 为 NULL；city 语义不变（已存在列）。
  """
  use Ecto.Migration

  def up do
    alter table(:flashback_wishes) do
      add(:signature, :string, null: false, default: "")
      add(:listed_at, :utc_datetime_usec, null: true)
      add(:hidden_at, :utc_datetime_usec, null: true)
    end

    # 存量行：signature 按 masked_name 口径回填
    execute("""
    UPDATE flashback_wishes w
    SET signature = (
      CASE
        WHEN p.full_name IS NULL OR p.full_name = '' THEN ''
        WHEN p.surname IS NOT NULL
             AND p.surname <> ''
             AND substring(p.full_name from 1 for char_length(p.surname)) = p.surname
        THEN p.surname || repeat('*', greatest(char_length(p.full_name) - char_length(p.surname), 1))
        ELSE substring(p.full_name from 1 for 1) || repeat('*', greatest(char_length(p.full_name) - 1, 1))
      END
    )
    FROM flashback_people p
    WHERE w.person_id = p.id AND w.signature = ''
    """)

    # KTD10 排序过滤 partial index（公开树）
    execute("""
    CREATE INDEX flashback_wishes_listed_at_public_index
      ON flashback_wishes (listed_at DESC)
      WHERE listed_at IS NOT NULL
        AND hidden_at IS NULL
        AND deleted_at IS NULL
        AND visibility = 'public'
    """)

    # admin 下架过滤
    execute("""
    CREATE INDEX flashback_wishes_hidden_at_index
      ON flashback_wishes (hidden_at)
      WHERE hidden_at IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS flashback_wishes_hidden_at_index")
    execute("DROP INDEX IF EXISTS flashback_wishes_listed_at_public_index")

    alter table(:flashback_wishes) do
      remove(:signature)
      remove(:listed_at)
      remove(:hidden_at)
    end
  end
end
