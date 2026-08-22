defmodule Mix.Tasks.Cgc2046.GenErrorCodesContract do
  @shortdoc "Regenerates priv/error_codes_contract.json from domain single source"

  @moduledoc """
  从 domain 层错误 code 单源（`Cgc2046.Errors.ErrorCodeContract` AST 提取）
  重新生成跨语言契约工件 `backend/priv/error_codes_contract.json`。

  #241 四清单机械联动：后端新增/改名 code 子句后跑本任务再生成；
  web（messages errors namespace）与 miniprogram（error-copy.ts）的文案表键
  由各自 contract test 断言 ⊆ 本工件——漂移即 CI 红灯。

  ## 用法

      mix cgc2046.gen_error_codes_contract           # 重新生成
      mix cgc2046.gen_error_codes_contract --check   # CI：过期即失败
  """

  use Mix.Task

  @switches [check: :boolean]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    contract = contract_payload()
    path = Path.expand("../../../priv/error_codes_contract.json", __DIR__)

    if opts[:check] do
      case File.read(path) do
        {:ok, existing} ->
          if existing == contract do
            Mix.shell().info("error_codes_contract.json is up to date")
          else
            Mix.raise(
              "error_codes_contract.json is stale — run `mix cgc2046.gen_error_codes_contract`"
            )
          end

        {:error, _} ->
          Mix.raise(
            "error_codes_contract.json is missing — run `mix cgc2046.gen_error_codes_contract`"
          )
      end
    else
      File.write!(path, contract)
      Mix.shell().info("wrote #{path}")
    end
  end

  defp contract_payload do
    Jason.encode!(%{"codes" => Cgc2046.Errors.ErrorCodeContract.codes()}, pretty: true)
  end
end
