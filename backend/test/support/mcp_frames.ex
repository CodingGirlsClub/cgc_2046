defmodule Cgc2046.McpFrames do
  @moduledoc """
  直调工具 `execute/2` 或 `Wrapper.run/4` 时用的测试 frame（ADR-0022）。

  `Wrapper.run/4` 读不到连接 token 的 kind 时按最严格处理，只放行学习凭证的工具名单。所以
  测试里直接构造的 frame 要像 `McpAuthPlug` 那样带上 kind。经真实 `/mcp` 入口的测试不需要它。
  """

  alias Anubis.Server.Frame

  @doc "终端 token 鉴权后的 frame：assigns 与 `McpAuthPlug` 写入的一致。"
  @spec terminal(term()) :: Frame.t()
  def terminal(user), do: %Frame{assigns: %{current_user: user, mcp_token_kind: :terminal}}
end
