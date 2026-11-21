defmodule Cgc2046.LlmGateway.SecretBox do
  @moduledoc """
  使用 Erlang `:crypto` AES-256-GCM 对上游 Provider API Key 做静态加密存储，
  并提供不可逆指纹与脱敏预览字符串。
  """

  @aad "cgc_2046:llm_provider_api_key:v1"
  @prefix "v1:"
  @iv_bytes 12
  @tag_bytes 16

  @spec encrypt(String.t()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    key = derived_key()

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_bytes, true)

    @prefix <> Base.encode64(iv <> tag <> ciphertext)
  end

  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, :decryption_failed}
  def decrypt(@prefix <> encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.decode64(encoded),
         true <- byte_size(raw) > @iv_bytes + @tag_bytes do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> = raw
      key = derived_key()

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    else
      _ -> {:error, :decryption_failed}
    end
  end

  def decrypt(_), do: {:error, :decryption_failed}

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

  defp derived_key do
    raw =
      case Application.get_env(:cgc_2046, :llm_gateway_encryption_key) do
        value when is_binary(value) and byte_size(value) > 0 ->
          value

        _ ->
          endpoint_cfg = Application.get_env(:cgc_2046, Cgc2046Web.Endpoint, [])

          Keyword.get(endpoint_cfg, :secret_key_base) ||
            raise "missing :llm_gateway_encryption_key or Endpoint :secret_key_base"
      end

    :crypto.hash(:sha256, "cgc_2046:llm_gateway_key:v1:" <> raw)
  end
end
