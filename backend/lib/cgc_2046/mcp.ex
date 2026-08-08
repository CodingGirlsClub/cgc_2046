defmodule Cgc2046.Mcp do
  @moduledoc """
  MCP 域（切片 D，#42–#45）：连接 token、工具调用审计、确认流 pending 操作。

  全平台唯一 MCP server（anubis_mcp，D6）的支撑资源域：
  - `Cgc2046.Mcp.Token`：连接 token（Bearer，绑用户不绑工作区，D13）
  - `Cgc2046.Mcp.ToolCallLog`：每次工具调用审计（D9）
  - `Cgc2046.Mcp.PendingOperation`：高风险工具确认流两阶段提交（D8 two-tool 模式，D-D3）
  """
  use Ash.Domain

  resources do
    resource(Cgc2046.Mcp.Token)
    resource(Cgc2046.Mcp.ToolCallLog)
    resource(Cgc2046.Mcp.PendingOperation)
  end
end
