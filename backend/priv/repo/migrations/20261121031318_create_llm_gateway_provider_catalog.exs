defmodule Cgc2046.Repo.Migrations.CreateLlmGatewayProviderCatalog do
  @moduledoc """
  LLM Gateway 动态 Provider / API Key / 模型目录表。
  """
  use Ecto.Migration

  def up do
    create table(:llm_providers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :protocol, :text, null: false, default: "openai_compatible"
      add :base_url, :text, null: false
      add :chat_path, :text
      add :models_path, :text
      add :priority, :integer, null: false, default: 100
      add :off_peak_discount_enabled, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:slug], name: "llm_providers_unique_slug_index")

    create constraint(:llm_providers, :llm_providers_protocol_valid,
             check: "protocol IN ('openai_compatible', 'anthropic')"
           )

    create constraint(:llm_providers, :llm_providers_priority_nonnegative, check: "priority >= 0")

    create table(:llm_provider_api_keys, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_id, references(:llm_providers, type: :uuid, on_delete: :delete_all),
        null: false

      add :label, :text, null: false
      add :encrypted_api_key, :text, null: false
      add :key_preview, :text, null: false
      add :key_fingerprint, :text, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_api_keys, [:provider_id, :key_fingerprint],
             name: "llm_provider_api_keys_unique_provider_fingerprint_index"
           )

    create index(:llm_provider_api_keys, [:provider_id])

    create table(:llm_provider_models, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_id, references(:llm_providers, type: :uuid, on_delete: :delete_all),
        null: false

      add :model_id, :text, null: false
      add :upstream_model_id, :text, null: false
      add :display_name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :context_window, :integer, null: false, default: 128_000
      add :max_output_tokens, :integer, null: false, default: 8_192
      add :supports_thinking, :boolean, null: false, default: false
      add :supports_tools, :boolean, null: false, default: true
      add :supports_images, :boolean, null: false, default: false
      add :reasoning_efforts, {:array, :text}, null: false, default: []
      add :cache_hit_price_mc, :bigint, null: false
      add :cache_miss_price_mc, :bigint, null: false
      add :output_price_mc, :bigint, null: false
      add :markup_ratio, :float, null: false, default: 1.5

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_models, [:provider_id, :model_id],
             name: "llm_provider_models_unique_provider_model_index"
           )

    create index(:llm_provider_models, [:model_id])

    create constraint(:llm_provider_models, :llm_provider_models_limits_positive,
             check: "context_window > 0 AND max_output_tokens > 0"
           )

    create constraint(:llm_provider_models, :llm_provider_models_pricing_valid,
             check:
               "cache_hit_price_mc >= 0 AND cache_miss_price_mc >= 0 AND output_price_mc >= 0 AND markup_ratio >= 1.0"
           )
  end

  def down do
    drop table(:llm_provider_models)
    drop table(:llm_provider_api_keys)
    drop table(:llm_providers)
  end
end
