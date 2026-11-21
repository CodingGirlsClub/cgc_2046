defmodule Cgc2046.LlmGateway.Provider do
  @moduledoc """
  平台管理员配置的上游大模型 Provider（OpenAI-compatible / Anthropic 原生协议）。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_providers")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :create do
      accept([
        :name,
        :slug,
        :protocol,
        :base_url,
        :chat_path,
        :models_path,
        :priority,
        :off_peak_discount_enabled,
        :enabled
      ])
    end

    update :update do
      accept([
        :name,
        :slug,
        :protocol,
        :base_url,
        :chat_path,
        :models_path,
        :priority,
        :off_peak_discount_enabled,
        :enabled
      ])
    end
  end

  policies do
    policy always() do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:slug, :string, allow_nil?: false, public?: true)

    attribute(:protocol, :atom,
      allow_nil?: false,
      default: :openai_compatible,
      public?: true,
      constraints: [one_of: [:openai_compatible, :anthropic]]
    )

    attribute(:base_url, :string, allow_nil?: false, public?: true)
    attribute(:chat_path, :string, allow_nil?: true, public?: true)
    attribute(:models_path, :string, allow_nil?: true, public?: true)

    attribute(:priority, :integer,
      allow_nil?: false,
      default: 100,
      public?: true,
      constraints: [min: 0]
    )

    attribute(:off_peak_discount_enabled, :boolean,
      allow_nil?: false,
      default: false,
      public?: true
    )

    attribute(:enabled, :boolean, allow_nil?: false, default: true, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:api_keys, Cgc2046.LlmGateway.ProviderApiKey, destination_attribute: :provider_id)
    has_many(:models, Cgc2046.LlmGateway.ProviderModel, destination_attribute: :provider_id)
  end

  identities do
    identity(:unique_slug, [:slug])
  end
end
