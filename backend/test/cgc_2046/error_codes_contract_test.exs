defmodule Cgc2046.ErrorCodesContractTest do
  @moduledoc """
  golden-file 契约守卫（#241 错误码四清单机械联动）。

  断言 `backend/priv/error_codes_contract.json` 与 domain 单源
  （`Cgc2046.Errors.ErrorCodeContract` AST 提取）完全一致——新增/改名
  code 子句后须运行 `mix cgc2046.gen_error_codes_contract` 再生成；
  前端文案表（web messages errors namespace / miniprogram error-copy.ts）
  由各自 contract test 断言键 ⊆ 本工件。

  纯函数测试，无 DB，可并行。
  """

  use ExUnit.Case, async: true

  @contract_path Path.expand("../../priv/error_codes_contract.json", __DIR__)

  test "committed error_codes_contract.json exists and matches domain single source" do
    contract = File.read!(@contract_path) |> Jason.decode!()

    assert contract["codes"] == Cgc2046.Errors.ErrorCodeContract.codes(),
           "error_codes_contract.json 已过期 —— 运行 `mix cgc2046.gen_error_codes_contract` 再生成"
  end
end
