defmodule Cgc2046.LlmGateway.SecretBoxTest do
  use ExUnit.Case, async: true

  alias Cgc2046.LlmGateway.SecretBox

  test "encrypts and decrypts arbitrary API keys via AES-256-GCM" do
    plaintext = "sk-ant-api03-very-secret-key-9876543210"
    ciphertext = SecretBox.encrypt(plaintext)

    assert String.starts_with?(ciphertext, "v1:")
    refute String.contains?(ciphertext, plaintext)
    assert {:ok, ^plaintext} = SecretBox.decrypt(ciphertext)
  end

  test "encrypt produces distinct nonces for identical plaintexts" do
    plaintext = "sk-same-key-twice"
    c1 = SecretBox.encrypt(plaintext)
    c2 = SecretBox.encrypt(plaintext)

    assert c1 != c2
    assert {:ok, ^plaintext} = SecretBox.decrypt(c1)
    assert {:ok, ^plaintext} = SecretBox.decrypt(c2)
  end

  test "rejects tampered or malformed ciphertext" do
    ciphertext = SecretBox.encrypt("sk-tamper-me")
    "v1:" <> b64 = ciphertext
    tampered = "v1:" <> String.reverse(b64)

    assert {:error, :decryption_failed} = SecretBox.decrypt(tampered)
    assert {:error, :decryption_failed} = SecretBox.decrypt("plain-text")
    assert {:error, :decryption_failed} = SecretBox.decrypt(nil)
  end

  test "mask and fingerprint handle short and normal keys safely" do
    assert SecretBox.mask("sk-1234567890abcdef") == "sk-1...cdef"
    assert SecretBox.mask("sk-12345") == "sk...45"
    assert SecretBox.mask("abc") == "****"

    fp1 = SecretBox.fingerprint("  sk-abc  ")
    fp2 = SecretBox.fingerprint("sk-abc")
    assert fp1 == fp2
    assert String.length(fp1) == 64
  end
end
