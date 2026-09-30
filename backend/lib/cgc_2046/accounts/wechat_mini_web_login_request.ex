defmodule Cgc2046.Accounts.WechatMiniWebLoginRequest do
  @moduledoc "Short-lived browser-bound approval; no user business data or raw credentials."
  use Ash.Resource,
    domain: Cgc2046.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:public_code, :string, allow_nil?: false, sensitive?: true)
    attribute(:browser_proof_hash, :binary, allow_nil?: false, sensitive?: true)
    attribute(:browser_rate_key, :string, allow_nil?: false, sensitive?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :approved, :consumed, :cancelled]]
    )

    attribute(:expires_at, :utc_datetime, allow_nil?: false)
    attribute(:approved_at, :utc_datetime)
    attribute(:consumed_at, :utc_datetime)
    attribute(:cancelled_at, :utc_datetime)
    attribute(:consumed_jti, :string, sensitive?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User)
  end

  actions do
    defaults([:read, create: [:public_code, :browser_proof_hash, :browser_rate_key, :expires_at]])

    update :transition do
      accept([:status])
      require_atomic?(false)
    end
  end

  identities do
    identity(:unique_public_code, [:public_code])
  end

  postgres do
    table("wechat_mini_web_login_requests")
    repo(Cgc2046.Repo)

    custom_indexes do
      index([:expires_at])
    end

    references do
      reference(:user, on_delete: :nothing)
    end
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end
end
