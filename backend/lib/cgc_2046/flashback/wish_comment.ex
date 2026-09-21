defmodule Cgc2046.Flashback.WishComment do
  @moduledoc """
  许愿留言（公开愿望的讨论面，R8）：正文 ≤500 字、去空白非空；软删后
  不再显示但保留审计（平台治理，KD7 无前置审核、软删兜底）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:wish_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:content, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:deleted_at, :utc_datetime, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:wish, Cgc2046.Flashback.Wish, attribute_writable?: true)
    belongs_to(:person, Cgc2046.Flashback.Person, attribute_writable?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:wish_id, :person_id, :content])
    end

    update :update do
      accept([:deleted_at])
    end
  end

  postgres do
    table("flashback_wish_comments")
    repo(Cgc2046.Repo)

    references do
      reference(:wish, on_delete: :delete)
      reference(:person, on_delete: :nothing)
    end
  end
end
