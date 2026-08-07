defmodule Cgc2046.Workflows.TestActions do
  @moduledoc """
  Workflow 引擎测试用 Jido Actions（阶段 2）。

  仅测试环境编译（elixirc_paths :test 含 test/support）。实现 `Jido.Action`
  契约（`run/2` 返回 `{:ok, map} | {:error, term}`），供 `JidoAdapter.build_workflow/1`
  的 auto 步骤引用。
  """

  @doc "把输入 text 转大写（验证事实传递）"
  defmodule Uppercase do
    use Jido.Action, name: "test_uppercase"

    def run(params, _context) do
      {:ok, %{text: String.upcase(params["text"] || params.text || "")}}
    end
  end

  @doc "把输入 text 追加感叹号（验证链式传递）"
  defmodule AppendExclamation do
    use Jido.Action, name: "test_append_exclamation"

    def run(params, _context) do
      {:ok, %{text: (params["text"] || params.text || "") <> "!"}}
    end
  end

  @doc "总是失败（验证 failed 路径）"
  defmodule AlwaysFail do
    use Jido.Action, name: "test_always_fail"

    def run(_params, _context), do: {:error, :boom}
  end
end
