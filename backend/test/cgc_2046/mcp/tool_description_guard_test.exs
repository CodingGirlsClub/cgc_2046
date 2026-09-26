defmodule Cgc2046.Mcp.ToolDescriptionGuardTest do
  @moduledoc """
  MCP 工具描述守卫：description 是调用方 agent 选工具、填参数的唯一依据。工具模块缺
  @moduledoc 又没定义 description/0 时，anubis 下发空字符串，agent 只看得到工具名。
  """
  use ExUnit.Case, async: true

  alias Cgc2046.Mcp.Server

  test "每个已注册工具都有非空 description" do
    missing =
      for %{name: name, handler: handler} <- Server.__components__(:tool),
          Code.ensure_loaded!(handler),
          String.trim(Anubis.Server.Component.get_description(handler)) == "",
          do: name

    assert missing == [],
           "以下工具没有 description（补 @moduledoc 或 description/0）：#{inspect(Enum.sort(missing))}"
  end

  # 下发给 agent 的文本（工具 description + 输入 schema 各字段 description）只写调用方
  # 需要的契约；需求编号、issue 号、内部模块名留在 @moduledoc
  @internal_ref ~r/ADR-\d|#\d{2,}|§|\bD-D\d|\b(?:KTD|KD|D)\d+\b|\b[RSUMQE]\d+\b|role-agent-journeys|Wrapper|PendingOperation|execute_confirmed|Policies\.|Cgc2046\.|\bAsh\./

  test "description 不含维护者内部编号与模块名" do
    leaked =
      for %{name: name, handler: handler} <- Server.__components__(:tool),
          Code.ensure_loaded!(handler),
          match = Regex.run(@internal_ref, Anubis.Server.Component.get_description(handler)),
          do: {name, hd(match)}

    assert leaked == [],
           "以下工具的 description 含内部编号（移到 @moduledoc，description/0 只写契约）：#{inspect(Enum.sort(leaked))}"
  end

  # input schema 的字段 description 与工具 description 一样下发；递归收集全部 description 串
  defp schema_descriptions(node, acc) when is_map(node) do
    acc =
      case node do
        %{"description" => d} when is_binary(d) -> [d | acc]
        _ -> acc
      end

    Enum.reduce(node, acc, fn
      {"description", _}, acc -> acc
      {_k, v}, acc -> schema_descriptions(v, acc)
    end)
  end

  defp schema_descriptions(_node, acc), do: acc

  test "输入 schema 的字段 description 不含维护者内部编号与模块名" do
    leaked =
      for %{name: name, handler: handler} <- Server.__components__(:tool),
          Code.ensure_loaded!(handler),
          desc =
            Enum.find(
              schema_descriptions(handler.input_schema, []),
              &Regex.match?(@internal_ref, &1)
            ),
          do: {name, Regex.run(@internal_ref, desc) |> hd()}

    assert leaked == [],
           "以下工具的参数 description 含内部编号（只写契约，编号留在 @moduledoc）：#{inspect(Enum.sort(leaked))}"
  end
end
