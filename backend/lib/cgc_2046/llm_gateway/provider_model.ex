defmodule Cgc2046.LlmGateway.ProviderModel do
  @moduledoc """
  上游 Provider 下管理员选定开放的模型目录项，含能力描述与逐模型单价配置。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_provider_models")
    repo(Cgc2046.Repo)

    references do
      reference(:provider, on_delete: :delete)
    end
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :create do
      upsert?(true)
      upsert_identity(:unique_provider_model)

      accept([
        :provider_id,
        :model_id,
        :upstream_model_id,
        :display_name,
        :enabled,
        :context_window,
        :max_output_tokens,
        :supports_thinking,
        :supports_tools,
        :supports_images,
        :reasoning_efforts,
        :cache_hit_price_mc,
        :cache_miss_price_mc,
        :output_price_mc,
        :markup_ratio
      ])
    end

    update :update do
      accept([
        :upstream_model_id,
        :display_name,
        :enabled,
        :context_window,
        :max_output_tokens,
        :supports_thinking,
        :supports_tools,
        :supports_images,
        :reasoning_efforts,
        :cache_hit_price_mc,
        :cache_miss_price_mc,
        :output_price_mc,
        :markup_ratio
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

    attribute(:model_id, :string, allow_nil?: false, public?: true)
    attribute(:upstream_model_id, :string, allow_nil?: false, public?: true)
    attribute(:display_name, :string, allow_nil?: false, public?: true)
    attribute(:enabled, :boolean, allow_nil?: false, default: true, public?: true)

    attribute(:context_window, :integer,
      allow_nil?: false,
      default: 128_000,
      public?: true,
      constraints: [min: 1]
    )

    attribute(:max_output_tokens, :integer,
      allow_nil?: false,
      default: 8_192,
      public?: true,
      constraints: [min: 1]
    )

    attribute(:supports_thinking, :boolean, allow_nil?: false, default: false, public?: true)
    attribute(:supports_tools, :boolean, allow_nil?: false, default: true, public?: true)
    attribute(:supports_images, :boolean, allow_nil?: false, default: false, public?: true)

    attribute(:reasoning_efforts, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:cache_hit_price_mc, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]
    )

    attribute(:cache_miss_price_mc, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]
    )

    attribute(:output_price_mc, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]
    )

    attribute(:markup_ratio, :float,
      allow_nil?: false,
      default: 1.5,
      public?: true,
      constraints: [min: 1.0]
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:provider, Cgc2046.LlmGateway.Provider,
      allow_nil?: false,
      public?: true
    )
  end

  identities do
    identity(:unique_provider_model, [:provider_id, :model_id])
  end
end
