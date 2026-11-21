defmodule Cgc2046.LlmGateway.ProviderCatalogTest do
  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.Accounts.AdminActionLog
  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.ProviderApiKey
  alias Cgc2046.LlmGateway.ProviderCatalog

  test "provider, api key, and model CRUD writes AdminActionLog and never leaks plaintext keys" do
    admin = Fixtures.platform_admin("catalog-admin")

    {:ok, provider} =
      ProviderCatalog.create_provider(admin, %{
        name: "DeepSeek Official",
        slug: "ds-official",
        protocol: "openai_compatible",
        base_url: "https://api.deepseek.com",
        priority: 10,
        off_peak_discount_enabled: true
      })

    assert provider.slug == "ds-official"
    assert provider.protocol == :openai_compatible |> to_string()
    assert provider.off_peak_discount_enabled == true

    {:ok, key1} =
      ProviderCatalog.add_api_key(admin, provider.id, %{
        label: "Primary Key",
        api_key: "sk-secret-key-000111222"
      })

    assert key1.key_preview == "sk-s...1222"
    refute Map.has_key?(key1, :encrypted_api_key)
    refute inspect(key1) =~ "sk-secret-key-000111222"

    # Duplicate key within the same provider is rejected.
    assert {:error, :key_duplicate} =
             ProviderCatalog.add_api_key(admin, provider.id, %{
               label: "Duplicate",
               api_key: "sk-secret-key-000111222"
             })

    {:ok, [saved_model]} =
      ProviderCatalog.save_provider_models(admin, provider.id, [
        %{
          model_id: "deepseek-chat",
          upstream_model_id: "deepseek-chat",
          display_name: "DeepSeek Chat",
          context_window: 128_000,
          max_output_tokens: 8_192,
          supports_thinking: false,
          supports_tools: true,
          supports_images: false,
          reasoning_efforts: [],
          cache_hit_price_mc: 200_000,
          cache_miss_price_mc: 2_000_000,
          output_price_mc: 3_000_000,
          markup_ratio: 1.5
        }
      ])

    assert saved_model.model_id == "deepseek-chat"

    # Available models only lists enabled provider + enabled key + enabled model, with marked-up user price.
    [available] = ProviderCatalog.list_available_models()
    assert available.model_id == "deepseek-chat"
    assert available.display_name == "DeepSeek Chat"
    assert available.input_price_mc == 3_000_000
    assert available.cache_hit_price_mc == 300_000
    assert available.output_price_mc == 4_500_000

    # Resolve runtime candidates returns UUID string IDs and decrypted key.
    [candidate] = ProviderCatalog.resolve_candidates_for_model("deepseek-chat")
    assert candidate.provider_id == provider.id
    assert candidate.id == "#{provider.slug}:#{key1.id}"
    assert candidate.api_key == "sk-secret-key-000111222"
    assert candidate.pricing.cache_miss_mc == 2_000_000

    # Disabling key removes model from available list and candidates.
    {:ok, _} = ProviderCatalog.update_api_key(admin, key1.id, %{enabled: false})
    assert ProviderCatalog.list_available_models() == []
    assert ProviderCatalog.resolve_candidates_for_model("deepseek-chat") == []

    # Re-enable key restores model.
    {:ok, _} = ProviderCatalog.update_api_key(admin, key1.id, %{enabled: true})
    assert length(ProviderCatalog.list_available_models()) == 1

    # Stored key in DB is encrypted and AdminActionLog has no plaintext key.
    db_key = Ash.get!(ProviderApiKey, key1.id, authorize?: false)
    assert String.starts_with?(db_key.encrypted_api_key, "v1:")

    logs =
      AdminActionLog
      |> Ash.Query.filter(actor_id == ^admin.id)
      |> Ash.read!(authorize?: false)

    actions = Enum.map(logs, & &1.action)
    assert :llm_provider_create in actions
    assert :llm_provider_api_key_create in actions
    assert :llm_provider_model_upsert in actions
    assert :llm_provider_api_key_update in actions
    refute Enum.any?(logs, &(inspect(&1.metadata) =~ "sk-secret-key-000111222"))

    # Deleting provider cascades to keys and models.
    assert :ok = ProviderCatalog.delete_provider(admin, provider.id)
    assert ProviderCatalog.list_providers() == []
    assert ProviderCatalog.list_available_models() == []
  end

  test "list_available_models deduplicates by provider priority" do
    admin = Fixtures.platform_admin("catalog-dedup")

    {:ok, backup} =
      ProviderCatalog.create_provider(admin, %{
        name: "Backup",
        slug: "backup-p",
        protocol: "openai_compatible",
        base_url: "https://backup.example.com/v1",
        priority: 200
      })

    {:ok, _} =
      ProviderCatalog.add_api_key(admin, backup.id, %{label: "k1", api_key: "sk-backup-111111"})

    {:ok, _} =
      ProviderCatalog.save_provider_models(admin, backup.id, [
        %{
          model_id: "deepseek-chat",
          display_name: "Backup Display",
          context_window: 64_000,
          max_output_tokens: 4_096,
          cache_hit_price_mc: 100_000,
          cache_miss_price_mc: 1_000_000,
          output_price_mc: 2_000_000
        }
      ])

    {:ok, primary} =
      ProviderCatalog.create_provider(admin, %{
        name: "Primary",
        slug: "primary-p",
        protocol: "openai_compatible",
        base_url: "https://primary.example.com/v1",
        priority: 10
      })

    {:ok, _} =
      ProviderCatalog.add_api_key(admin, primary.id, %{label: "k1", api_key: "sk-primary-111111"})

    {:ok, _} =
      ProviderCatalog.save_provider_models(admin, primary.id, [
        %{
          model_id: "deepseek-chat",
          display_name: "Primary Display",
          context_window: 128_000,
          max_output_tokens: 8_192,
          cache_hit_price_mc: 200_000,
          cache_miss_price_mc: 2_000_000,
          output_price_mc: 3_000_000
        }
      ])

    [available] = ProviderCatalog.list_available_models()
    assert available.display_name == "Primary Display"

    candidates = ProviderCatalog.resolve_candidates_for_model("deepseek-chat")
    assert Enum.map(candidates, & &1.provider_slug) == ["primary-p", "backup-p"]
  end

  test "fetch_upstream_models discovers OpenAI and Anthropic models with stored key and presets" do
    admin = Fixtures.platform_admin("catalog-discovery")

    {:ok, openai_p} =
      ProviderCatalog.create_provider(admin, %{
        name: "OpenAI Test",
        slug: "openai-test",
        protocol: "openai_compatible",
        base_url: "https://mock-openai.example.com/v1"
      })

    {:ok, _} =
      ProviderCatalog.add_api_key(admin, openai_p.id, %{
        label: "stored",
        api_key: "sk-openai-stored-123"
      })

    {:ok, discovered_openai} =
      ProviderCatalog.fetch_upstream_models(openai_p.id, nil,
        req_plug: fn conn ->
          assert conn.request_path == "/v1/models"

          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer sk-openai-stored-123"
                 ]

          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "deepseek-chat"},
              %{"id" => "custom-model-x", "context_length" => 32_768}
            ]
          })
        end
      )

    assert [ds, custom] = discovered_openai
    assert ds.model_id == "deepseek-chat"
    assert ds.preset_matched == true
    assert ds.cache_miss_price_mc == 2_000_000

    assert custom.model_id == "custom-model-x"
    assert custom.preset_matched == false
    assert custom.context_window == 32_768

    {:ok, anthropic_p} =
      ProviderCatalog.create_provider(admin, %{
        name: "Anthropic Test",
        slug: "anthropic-test",
        protocol: "anthropic",
        base_url: "https://mock-anthropic.example.com"
      })

    {:ok, discovered_anthropic} =
      ProviderCatalog.fetch_upstream_models(anthropic_p.id, "sk-ant-override-999",
        req_plug: fn conn ->
          assert conn.request_path == "/v1/models"
          assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-override-999"]
          assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "claude-sonnet-4-5-20250929", "display_name" => "Claude Sonnet 4.5"}
            ]
          })
        end
      )

    assert [claude] = discovered_anthropic
    assert claude.model_id == "claude-sonnet-4-5-20250929"
    assert claude.preset_matched == true
    assert claude.supports_thinking == true
    assert claude.supports_images == true
  end

  test "SSRF guard rejects private and metadata URLs when allow_private is false" do
    alias Cgc2046.LlmGateway.UpstreamDiscovery

    for bad_url <- [
          "http://api.deepseek.com",
          "https://localhost/v1",
          "https://127.0.0.1/v1",
          "https://10.0.0.1/v1",
          "https://172.16.0.1/v1",
          "https://192.168.1.1/v1",
          "https://169.254.169.254/latest",
          "https://[::1]/v1",
          "https://user:pass@api.deepseek.com"
        ] do
      assert {:error, :invalid_url} =
               UpstreamDiscovery.validate_base_url(bad_url, allow_private: false),
             "expected #{bad_url} to be rejected"
    end

    assert {:ok, "https://api.deepseek.com"} =
             UpstreamDiscovery.validate_base_url("https://api.deepseek.com/",
               allow_private: false
             )
  end
end
