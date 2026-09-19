defmodule Cgc2046.Flashback.WishEndorsement do
  @moduledoc """
  许愿附议：一人一愿一票幂等（`unique_wish_person`），重复附议无副作用。
  计数不落冗余列（白名单纪律），读出口为投影实时 COUNT。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:wish_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:wish, Cgc2046.Flashback.Wish, attribute_writable?: true)
    belongs_to(:person, Cgc2046.Flashback.Person, attribute_writable?: true)
  end

  identities do
    identity(:unique_wish_person, [:wish_id, :person_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:wish_id, :person_id])
      upsert?(true)
      upsert_identity(:unique_wish_person)
    end
  end

  postgres do
    table("flashback_wish_endorsements")
    repo(Cgc2046.Repo)

    references do
      reference(:wish, on_delete: :delete)
      reference(:person, on_delete: :nothing)
    end
  end
end
