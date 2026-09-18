defmodule Cgc2046.Repo.Migrations.CreateFlashbackRedemptions do
  use Ecto.Migration

  def change do
    create table(:flashback_redemptions, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:person_id, references(:flashback_people, type: :uuid, column: :id), null: false)

      # 用户主动提交的兑换渠道信息（收款方式与账号）——admin-only 读面。
      add(:channel_note, :text, null: false)

      add(:status, :text, null: false, default: "pending")
      add(:handled_note, :text)

      timestamps(type: :utc_datetime_usec)
    end

    # 一人一行：重复提交 = 更新渠道信息（flashbackRedeem 幂等）。
    # 索引名对齐 identity 推导名（identity_index_guard 惯例，同 flashback_todays）。
    create(
      unique_index(:flashback_redemptions, [:person_id],
        name: :flashback_redemptions_unique_person_index
      )
    )
  end
end
