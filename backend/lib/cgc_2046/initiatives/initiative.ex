defmodule Cgc2046.Initiatives.Initiative do
  @moduledoc """
  平台级 Initiative；不属于任何 Workspace。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Initiatives

  @statuses [:draft, :open, :closed]

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:slug, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:hashtag, :string, public?: true, writable?: true)
    attribute(:description, :string, public?: true, writable?: true)
    attribute(:window_starts_at, :utc_datetime, public?: true, writable?: true)
    attribute(:window_ends_at, :utc_datetime, public?: true, writable?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      public?: true,
      writable?: false,
      constraints: [one_of: @statuses]
    )

    attribute(:created_by, :uuid, allow_nil?: false, public?: true, writable?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:creator, Cgc2046.Accounts.User,
      source_attribute: :created_by,
      destination_attribute: :id,
      define_attribute?: false
    )

    has_many(:rules, Cgc2046.Initiatives.InitiativeRule, destination_attribute: :initiative_id)
    has_many(:events, Cgc2046.Events.Event, destination_attribute: :initiative_id)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :name,
        :slug,
        :hashtag,
        :description,
        :window_starts_at,
        :window_ends_at,
        :created_by
      ])

      change(set_attribute(:status, :draft))

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_create, target_type: :initiative}
      )
    end

    update :update do
      require_atomic?(false)
      accept([:name, :slug, :hashtag, :description, :window_starts_at, :window_ends_at])

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_update, target_type: :initiative}
      )
    end

    update :open do
      require_atomic?(false)
      accept([])

      change(fn cs, _ -> Ash.Changeset.before_action(cs, &transition(&1, :draft, :open)) end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_open, target_type: :initiative}
      )
    end

    update :close do
      require_atomic?(false)
      accept([])
      change(fn cs, _ -> Ash.Changeset.before_action(cs, &transition(&1, :open, :closed)) end)

      change(
        {Cgc2046.Accounts.Changes.LogAdminAction,
         action: :initiative_close, target_type: :initiative}
      )
    end
  end

  validations do
    validate(match(:slug, ~r/^[a-z0-9][a-z0-9-]*$/))
  end

  defp transition(changeset, from, to) do
    repo = Cgc2046.Repo

    with {:ok, %{rows: [[status]]}} <-
           repo.query("SELECT status FROM initiatives WHERE id = $1 FOR UPDATE", [
             repo.uuid!(changeset.data.id)
           ]),
         true <- status == to_string(from),
         true <- to != :open or Cgc2046.Initiatives.RuleInheritance.ready?(changeset.data.id) do
      Ash.Changeset.force_change_attribute(changeset, :status, to)
    else
      _ ->
        Ash.Changeset.add_error(
          changeset,
          "invalid initiative transition or missing all four rules"
        )
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  postgres do
    table("initiatives")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end
