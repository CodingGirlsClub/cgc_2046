defmodule Cgc2046.LlmGateway.SecretBox do
  @moduledoc """
  使用 Erlang `:crypto` AES-256-GCM 对上游 Provider API Key 做静态加密存储，
  并提供不可逆指纹与脱敏预览字符串。

  加密优先使用独立主密钥 `:llm_gateway_encryption_key`（部署期注入），未配置时
  回落到 `Endpoint :secret_key_base`。解密同时尝试两把密钥：独立主密钥上线前用
  回落密钥写入的密文仍然可读，避免升级瞬间渠道失效。迁移历史数据用
  `Cgc2046.LlmGateway.ProviderCatalog.reencrypt_api_keys/0`。
  """

  @aad "cgc_2046:llm_provider_api_key:v1"
  @prefix "v1:"
  @iv_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    key = encryption_key()

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_bytes, true)

    @prefix <> Base.encode64(iv <> tag <> ciphertext)
  end

  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, :decryption_failed}
  def decrypt(ciphertext) do
    case decrypt_with_source(ciphertext) do
      {:ok, plaintext, _source} -> {:ok, plaintext}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  解密并返回命中的密钥来源：`:primary`（独立主密钥）或 `:fallback`
  （`secret_key_base` 回落）。调用方据此提示重加密。
  """
  @spec decrypt_with_source(String.t()) ::
          {:ok, String.t(), :primary | :fallback} | {:error, :decryption_failed}
  def decrypt_with_source(@prefix <> encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.decode64(encoded),
         true <- byte_size(raw) > @iv_bytes + @tag_bytes do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> = raw

      Enum.find_value(derived_keys(), {:error, :decryption_failed}, fn {source, key} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext, source}
          :error -> nil
        end
      end)
    else
      _ -> {:error, :decryption_failed}
    end
  end

  def decrypt_with_source(_), do: {:error, :decryption_failed}

  @doc """
  是否配置了独立主密钥；未配置时只能用 `secret_key_base` 回落。
  """
  @spec primary_configured?() :: boolean()
  def primary_configured?, do: not is_nil(primary_secret())

  @spec mask(String.t()) :: String.t()
  def mask(plaintext) when is_binary(plaintext) do
    trimmed = String.trim(plaintext)
    len = String.length(trimmed)

    cond do
      len >= 12 ->
        String.slice(trimmed, 0, 4) <> "..." <> String.slice(trimmed, -4, 4)

      len >= 6 ->
        String.slice(trimmed, 0, 2) <> "..." <> String.slice(trimmed, -2, 2)

      true ->
        "****"
    end
  end

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, String.trim(plaintext)) |> Base.encode16(case: :lower)
  end

  defp encryption_key do
    case primary_secret() || fallback_secret() do
      nil -> raise "missing :llm_gateway_encryption_key or Endpoint :secret_key_base"
      raw -> derive(raw)
    end
  end

  # 顺序即优先级：新写入永远用主密钥，历史密文靠回落密钥兜底。
  defp derived_keys do
    [{:primary, primary_secret()}, {:fallback, fallback_secret()}]
    |> Enum.reject(fn {_source, raw} -> is_nil(raw) end)
    |> Enum.map(fn {source, raw} -> {source, derive(raw)} end)
    |> Enum.uniq_by(fn {_source, key} -> key end)
  end

  defp derive(raw), do: :crypto.hash(:sha256, "cgc_2046:llm_gateway_key:v1:" <> raw)

  defp primary_secret do
    case Application.get_env(:cgc_2046, :llm_gateway_encryption_key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> nil
    end
  end

  defp fallback_secret do
    :cgc_2046
    |> Application.get_env(Cgc2046Web.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end
end
