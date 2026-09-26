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

  # 下发的 description 只写调用方需要的契约；需求编号、issue 号、内部模块名留在 @moduledoc
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
end
