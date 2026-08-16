defmodule Cgc2046.Mcp.Server do
  @moduledoc """
  全平台唯一 MCP server（D6 / #42）：anubis_mcp streamable HTTP。

  工具集（D7 子集，切片 D 最小闭环）：
  - 读：get_workspace_context / list_members / get_workflow / get_step_output
    （get_agent_instruction：D10 任务指令模式，拉取 Agent 定义 prompt/skills/授权；
    plan 020 只留接口语义，不实现——roadmap）
  - 写：save_step_output
  - 管理（确认流 two-tool，D-D3）：create_invitation
  - 内置：confirm_operation / cancel_operation

  鉴权：`Cgc2046Web.Plugs.McpAuthPlug` 验 Bearer → `frame.assigns[:current_user]`；
  每工具调用经 `Cgc2046.Mcp.Wrapper` 做 workspace_id 必填校验（D12）+ membership
  鉴权 + ToolCallLog 审计（D9）。

  elicitation 不启用（目标客户端均不支持，见 research §5b；D8 用 two-tool 模式）。
  """
  use Anubis.Server,
    name: "cgc-2046",
    version: "0.1.0",
    capabilities: [:tools]

  component(Cgc2046.Mcp.Tools.GetWorkspaceContext)
  component(Cgc2046.Mcp.Tools.ListMembers)
  component(Cgc2046.Mcp.Tools.GetWorkflow)
  component(Cgc2046.Mcp.Tools.GetStepOutput)
  component(Cgc2046.Mcp.Tools.SaveStepOutput)
  component(Cgc2046.Mcp.Tools.CreateInvitation)
  component(Cgc2046.Mcp.Tools.ConfirmOperation)
  component(Cgc2046.Mcp.Tools.CancelOperation)
end
