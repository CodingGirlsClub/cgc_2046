defmodule Cgc2046.Repo.Migrations.CreateWishExpectations do
  @moduledoc """
  U2（KTD2）：flashback_wish_expectations——「期待」动作，与附议双指标分离。

  voter_key 复用 likes 白名单口径：`u:<user_id>` / `a:<device_uuid>`，
  匿名/登录同空间。唯一约束 `(wish_id, voter_key)` upsert 承接并发双击。
  双窗限频由 domain 层 `WishExpectations.set_expectation/3` 复用 `likes.ex`
  现有口径：voter 30/min + IP 60/h。
  """
  use Ecto.Migration

  def change do
    create table(:flashback_wish_expectations, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :wish_id,
        references(:flashback_wishes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:voter_key, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:flashback_wish_expectations, [:wish_id, :voter_key],
        name: :flashback_wish_expectations_unique_wish_voter_index
      )
    )

    create(index(:flashback_wish_expectations, [:wish_id]))
  end
end
