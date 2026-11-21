defmodule Cgc2046.LlmGateway.SecretBoxLegacyKeyTest do
  # 修改全局 :llm_gateway_encryption_key 配置，必须串行执行，避免污染 async 测试。
  use Cgc2046.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.LlmGateway.ProviderCatalog
  alias Cgc2046.LlmGateway.SecretBox

  @primary "test-primary-master-key"

  setup do
    previous = Application.get_env(:cgc_2046, :llm_gateway_encryption_key)
    Application.delete_env(:cgc_2046, :llm_gateway_encryption_key)
    ProviderCatalog.invalidate_cache!()

    on_exit(fn ->
      restore_primary(previous)
      ProviderCatalog.invalidate_cache!()
    end)

    :ok
  end

  test "fallback ciphertext stays readable after the primary key is configured, then reencrypt migrates it" do
    plaintext = "sk-legacy-round-trip"

    {provider, api_key} = seed_provider_key(plaintext)
    legacy_ciphertext = stored_ciphertext(api_key.id)

    # 用回落密钥写入时不标记为主密钥。
    assert {:ok, ^plaintext, :fallback} = SecretBox.decrypt_with_source(legacy_ciphertext)
    assert SecretBox.primary_configured?() == false

    # 启用独立主密钥：旧密文必须仍然可读，否则升级瞬间渠道全断。
    Application.put_env(:cgc_2046, :llm_gateway_encryption_key, @primary)
    ProviderCatalog.invalidate_cache!()

    assert SecretBox.primary_configured?() == true
    assert {:ok, ^plaintext, :fallback} = SecretBox.decrypt_with_source(legacy_ciphertext)

    log =
      capture_log(fn ->
        assert [%{api_key: ^plaintext}] =
                 ProviderCatalog.resolve_candidates_for_model("legacy-model")
      end)

    assert log =~ "still encrypted with the fallback secret_key_base key"
    assert log =~ "provider=legacy-provider"
    assert log =~ "key_id=#{api_key.id}"
    refute log =~ plaintext

    assert {:ok, %{reencrypted: 1, failed: 0}} = ProviderCatalog.reencrypt_api_keys()

    migrated_ciphertext = stored_ciphertext(api_key.id)
    refute migrated_ciphertext == legacy_ciphertext
    assert {:ok, ^plaintext, :primary} = SecretBox.decrypt_with_source(migrated_ciphertext)

    # 重加密后不再依赖 secret_key_base：去掉主密钥即无法解密。
    Application.delete_env(:cgc_2046, :llm_gateway_encryption_key)
    assert {:error, :decryption_failed} = SecretBox.decrypt(migrated_ciphertext)

    Application.put_env(:cgc_2046, :llm_gateway_encryption_key, @primary)
    ProviderCatalog.invalidate_cache!()
    assert [%{api_key: ^plaintext}] = ProviderCatalog.resolve_candidates_for_model("legacy-model")

    assert provider.slug == "legacy-provider"
  end

  test "reencrypt refuses to run without a dedicated master key" do
    seed_provider_key("sk-no-primary")

    assert {:error, :primary_key_missing} = ProviderCatalog.reencrypt_api_keys()
  end

  test "undecryptable rows are preserved and counted as failed" do
    {_provider, api_key} = seed_provider_key("sk-broken-row")

    Repo.update_all(
      from(k in "llm_provider_api_keys", where: k.id == type(^api_key.id, Ecto.UUID)),
      set: [encrypted_api_key: "v1:" <> Base.encode64(:crypto.strong_rand_bytes(48))]
    )

    corrupted = stored_ciphertext(api_key.id)
    Application.put_env(:cgc_2046, :llm_gateway_encryption_key, @primary)

    assert {:ok, %{reencrypted: 0, failed: 1}} = ProviderCatalog.reencrypt_api_keys()
    assert stored_ciphertext(api_key.id) == corrupted
  end

  defp seed_provider_key(plaintext) do
    admin = Fixtures.platform_admin("legacy-key-admin")
    suffix = System.unique_integer([:positive])

    {:ok, provider} =
      ProviderCatalog.create_provider(admin, %{
        name: "Legacy Provider",
        slug: "legacy-provider",
        protocol: "openai_compatible",
        base_url: "https://api.example.com",
        priority: 10,
        off_peak_discount_enabled: false
      })

    {:ok, api_key} =
      ProviderCatalog.add_api_key(admin, provider.id, %{
        label: "Legacy #{suffix}",
        api_key: plaintext
      })

    {:ok, _} =
      ProviderCatalog.save_provider_models(admin, provider.id, [
        %{
          model_id: "legacy-model",
          upstream_model_id: "legacy-model",
          display_name: "Legacy Model",
          context_window: 128_000,
          max_output_tokens: 8_192,
          supports_thinking: false,
          supports_tools: true,
          supports_images: false,
          reasoning_efforts: [],
          cache_hit_price_mc: 0,
          cache_miss_price_mc: 1_000_000,
          output_price_mc: 2_000_000,
          markup_ratio: 1.0
        }
      ])

    {provider, api_key}
  end

  defp stored_ciphertext(key_id) do
    Repo.one(
      from(k in "llm_provider_api_keys",
        where: k.id == type(^key_id, Ecto.UUID),
        select: k.encrypted_api_key
      )
    )
  end

  defp restore_primary(nil), do: Application.delete_env(:cgc_2046, :llm_gateway_encryption_key)

  defp restore_primary(value),
    do: Application.put_env(:cgc_2046, :llm_gateway_encryption_key, value)
end
