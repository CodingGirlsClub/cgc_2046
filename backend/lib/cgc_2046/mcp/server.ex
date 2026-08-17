defmodule Cgc2046.Mcp.Server do
  @moduledoc """
  全平台唯一 MCP server（D6 / #42）：anubis_mcp streamable HTTP。

  工具集(12,切片 H U3 后):
  - 读:get_workspace_context / list_members / get_workflow / get_step_output
  - 写:save_step_output
  - 管理(确认流 two-tool,D-D3):create_invitation
  - 内置:confirm_operation / cancel_operation
  - 课程学习(切片 H U3,#180):get_course_content / get_learning_records /
    save_learning_records / save_course_content(学员侧三工具带 `meta: %{membership: :deferred}`
    声明,授权锚 user_id,见各工具 moduledoc)

  （get_agent_instruction：D10 任务指令模式，拉取 Agent 定义 prompt/skills/授权；
  plan 020 只留接口语义，不实现——roadmap）

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
  # 课程 issue 学习闭环(切片 H U3,#180):工具面 8 → 12
  component(Cgc2046.Mcp.Tools.GetCourseContent)
  component(Cgc2046.Mcp.Tools.GetLearningRecords)
  component(Cgc2046.Mcp.Tools.SaveLearningRecords)
  component(Cgc2046.Mcp.Tools.SaveCourseContent)
end
