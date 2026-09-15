defmodule Cgc2046.Notifications.NotificationDelivery do
  @moduledoc "Durable notification outbox row."

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Notifications

  attributes do
    uuid_primary_key(:id)
    attribute(:idempotency_key, :string, allow_nil?: false)
    attribute(:user_id, :uuid, allow_nil?: false, public?: true)
    attribute(:platform, :string, public?: true)
    attribute(:identity_uid, :string, public?: true)
    attribute(:template_key, :string, allow_nil?: false, public?: true)
    attribute(:data, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:job_meta, :map, allow_nil?: false, default: %{}, public?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :sent, :failed]]
    )

    attribute(:attempts, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:last_error, :string, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :idempotency_key,
        :user_id,
        :platform,
        :identity_uid,
        :template_key,
        :data,
        :job_meta,
        :status,
        :attempts,
        :last_error
      ])
    end

    update :mark_sent do
      accept([])
      change(set_attribute(:status, :sent))
    end

    update :assign_identity do
      require_atomic?(false)
      accept([:platform, :identity_uid])
      change(set_attribute(:status, :pending))
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:last_error])
      change(set_attribute(:status, :failed))
      change(fn changeset, _ -> Ash.Changeset.increment(changeset, :attempts, 1) end)
    end
  end

  identities do
    identity(:unique_delivery, [:idempotency_key])
  end

  postgres do
    table("notification_deliveries")
    repo(Cgc2046.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type([:create, :update]) do
      authorize_if(always())
    end
  end
end
