defmodule Mix.Tasks.Cgc2046.ReencryptLlmKeys do
  @shortdoc "Re-encrypts stored LLM provider keys with the dedicated master key"

  @moduledoc """
  把 `llm_provider_api_keys` 中仍用 `secret_key_base` 回落密钥加密的行，重加密为
  独立主密钥 `LLM_GATEWAY_ENCRYPTION_KEY`（对应
  `Cgc2046.LlmGateway.ProviderCatalog.reencrypt_api_keys/0`）。

  上线独立主密钥后旧密文仍能解密（运行时依次尝试主密钥与回落密钥），但轮换
  `secret_key_base` 会使其失效，因此应尽早执行本任务。无法解密的行保持原样，
  任务会报告数量——这些行需要在管理后台重新录入。

  ## 用法

  源码环境：

      mix cgc2046.reencrypt_llm_keys

  生产 release（运行时镜像只含 `bin/cgc_2046`、没有 mix）：

      bin/cgc_2046 eval "Cgc2046.Release.reencrypt_llm_keys"
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Cgc2046.LlmGateway.ProviderCatalog.reencrypt_api_keys() do
      {:ok, %{reencrypted: reencrypted, failed: 0}} ->
        Mix.shell().info("reencrypted #{reencrypted} llm provider api key(s)")

      {:ok, %{reencrypted: reencrypted, failed: failed}} ->
        Mix.shell().info(
          "reencrypted #{reencrypted} llm provider api key(s); " <>
            "#{failed} could not be decrypted and must be re-entered in the admin console"
        )

      {:error, :primary_key_missing} ->
        Mix.raise("LLM_GATEWAY_ENCRYPTION_KEY is not configured; cannot re-encrypt")
    end
  end
end
