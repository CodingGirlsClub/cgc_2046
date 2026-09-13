defmodule Cgc2046.Events.EventModerator do
  @moduledoc """
  Event 级主理人关联；目标用户无需 Workspace membership。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Events

  attributes do
    uuid_primary_key(:id)
    attribute(:workspace_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:event_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:user_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:assigned_by, :uuid, public?: true, writable?: true)

    attribute(:assigned_at, :utc_datetime,
      allow_nil?: false,
      default: &DateTime.utc_now/0,
      public?: true,
      writable?: true
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:workspace_id)
    global?(true)
  end

  relationships do
    belongs_to(:event, Cgc2046.Events.Event,
      source_attribute: :event_id,
      destination_attribute: :id,
      define_attribute?: false
    )

    belongs_to(:user, Cgc2046.Accounts.User,
      source_attribute: :user_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  actions do
    defaults([:read])

    create :assign do
      accept([:workspace_id, :event_id, :user_id, :assigned_by, :assigned_at])
    end

    destroy :remove do
      accept([])
    end
  end

  identities do
    identity(:unique_event_user, [:event_id, :user_id])
  end

  postgres do
    table("event_moderators")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
      authorize_if(Cgc2046.Accounts.Policies.WorkspaceActorIsOwnerOrAdmin)
    end
  end
end
