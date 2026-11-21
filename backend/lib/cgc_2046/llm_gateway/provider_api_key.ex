defmodule Cgc2046.LlmGateway.ProviderApiKey do
  @moduledoc """
  上游 LLM Provider 的 API Key 池条目。

  `encrypted_api_key` 以 AES-256-GCM 密文存储且不向读面暴露；对外仅暴露脱敏
  `key_preview`，并用 `key_fingerprint` 保证同 Provider 内不重复录入相同密钥。
  """

  use Ash.Resource,
    domain: Cgc2046.LlmGateway,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("llm_provider_api_keys")
    repo(Cgc2046.Repo)

    references do
      reference(:provider, on_delete: :delete)
    end
  end

  actions do
    default_accept([])
    defaults([:read, :destroy])

    create :create do
      accept([:provider_id, :label, :enabled])
    end

    update :update do
      accept([:label, :enabled])
    end
  end

  policies do
    policy always() do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:label, :string, allow_nil?: false, public?: true)

    attribute(:encrypted_api_key, :string,
      allow_nil?: false,
      public?: false,
      sensitive?: true,
      writable?: false
    )

    attribute(:key_preview, :string, allow_nil?: false, public?: true, writable?: false)
    attribute(:key_fingerprint, :string, allow_nil?: false, public?: false, writable?: false)
    attribute(:enabled, :boolean, allow_nil?: false, default: true, public?: true)

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
    identity(:unique_provider_fingerprint, [:provider_id, :key_fingerprint])
  end
end
