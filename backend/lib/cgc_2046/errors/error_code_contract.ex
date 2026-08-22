defmodule Cgc2046.Errors.ErrorCodeContract do
  @moduledoc """
  业务错误 code 契约单源提取器（#241 四清单机械联动）。

  AST 扫描 domain 层（lib/cgc_2046/，不含 cgc_2046_web 的 auth/infra code）
  提取两种字面量：

  1. `defp domain_error_code(...), do: "code"`（五个资源文件的显式子句；
     动态拼接兜底子句 `"prefix_" <> ...` 非字面量，不收——故兜底动态 code
     不进契约，前端也不得为其配文案，需要文案先显式子句化）
  2. `code: "code"` 关键字字面量（validate_workspace_join_policy /
     membership_context / user 等 domain 内手写错误信封）

  消费方：
  - `mix cgc2046.gen_error_codes_contract [--check]` → priv/error_codes_contract.json
  - error_codes_contract_test.exs（golden 新鲜度守卫）
  - web/lib/error-codes.contract.test.ts 与 miniprogram/tests/
    error-codes.contract.test.ts（前端文案表键 ⊆ 本契约）

  仅 dev/test/mix task 调用（AST 解析依赖源码文件，release 运行时不可用）。
  """

  @domain_root Path.expand("..", __DIR__)

  @spec codes() :: [String.t()]
  def codes do
    @domain_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&extract_from_file/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_from_file(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()
    {_, acc} = Macro.prewalk(ast, [], &collect/2)
    acc
  end

  # defp domain_error_code(...), do: "literal"（含 when 守卫与跨行形态）
  defp collect({:defp, _, [head, [do: body]]} = node, acc) when is_binary(body) do
    if fun_name(head) == :domain_error_code, do: {node, [body | acc]}, else: {node, acc}
  end

  # keyword/map 项 code: "literal"（AST 中为 {:code, "literal"} 二元组）
  defp collect({:code, code} = node, acc) when is_binary(code), do: {node, [code | acc]}

  defp collect(node, acc), do: {node, acc}

  defp fun_name({:when, _, [call | _]}), do: fun_name(call)
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: nil
end
