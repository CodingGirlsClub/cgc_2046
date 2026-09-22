defmodule Cgc2046.Repo.Migrations.CreateWishReportsAndUserCreditField do
  @moduledoc """
  U5（KTD5）：
  1. `flashback_reports`——公开 mutation `flashbackReportWish` 的服务端记录。
     reason 预设 + 自由文本 ≤200；status pending/dismissed/actioned。
     reporter 三轨 voter 复用 likes 白名单口径（u:/a:）。
  2. `users.wishes_review_required_at`——作者 credit reduction 时间戳（G1 pin）。
     admin set_hidden 后置位；新公开 wish 该 user 名下默认 hidden_at 待审。
  """
  use Ecto.Migration

  def up do
    create table(:flashback_reports, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:target_type, :string, null: false)  # "wish" / "wish_comment"
      add(:target_id, :uuid, null: false)
      add(:reporter_user_id, :uuid, null: true)
      add(:reporter_voter_key, :string, null: true)
      add(:reason_type, :string, null: false)   # preset
      add(:reason_free, :string, null: true)
      add(:status, :string, null: false, default: "pending")  # pending/dismissed/actioned
      add(:acted_at, :utc_datetime_usec, null: true)
      add(:acted_by_user_id, :uuid, null: true)

      timestamps(type: :utc_datetime)
    end

    create(index(:flashback_reports, [:status]))
    create(index(:flashback_reports, [:target_type, :target_id]))
    create(index(:flashback_reports, [:inserted_at]))

    alter table(:users) do
      add(:wishes_review_required_at, :utc_datetime_usec, null: true)
    end

    execute("""
    CREATE INDEX users_wishes_review_required_at_index
      ON users (wishes_review_required_at)
      WHERE wishes_review_required_at IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS users_wishes_review_required_at_index")

    alter table(:users) do
      remove(:wishes_review_required_at)
    end

    drop(table(:flashback_reports))
  end
end
