defmodule Cgc2046.Flashback.WishExpectation do
  @moduledoc """
  许愿期待（KTD2 U2）：voter 对某愿望按 `u:<user_id>` / `a:<device_uuid>` 去重
  （`(wish_id, voter_key)` 唯一，upsert 承接并发双击）。
  计数不落冗余列（白名单纪律），读出口 = `WishExpectations.count_for_wish/1`。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:wish_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:voter_key, :string, allow_nil?: false, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:wish, Cgc2046.Flashback.Wish, attribute_writable?: true)
  end

  identities do
    identity(:unique_wish_voter, [:wish_id, :voter_key])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:wish_id, :voter_key])
      upsert?(true)
      upsert_identity(:unique_wish_voter)
    end
  end

  postgres do
    table("flashback_wish_expectations")
    repo(Cgc2046.Repo)

    references do
      reference(:wish, on_delete: :delete)
    end
  end
end
