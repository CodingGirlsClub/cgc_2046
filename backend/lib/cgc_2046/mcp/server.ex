defmodule Cgc2046.Mcp.Server do
  @moduledoc """
  全平台唯一 MCP server（D6 / #42）：anubis_mcp streamable HTTP。

  工具集(20,role-agent-journeys-v2 S1 角色工作台基座三工具后):
  - 读:get_workspace_context / list_members / list_join_requests / get_workflow / get_step_output
  - 公开浏览(membership: :public,KTD2/KTD3;任何持连接 token 的登录用户,匿名白名单口径):
    list_public_offerings / get_public_offering
  - 角色工作台基座(S1,R2/R3/R8):list_my_workspaces(workspace_id: :optional,
    actor 锚定跨工作台读) / get_role_playbook(optional+deferred 双键,工具层四分支
    授权) / list_my_tasks(member-only,PendingApprovals 聚合)
  - 写:save_step_output
  - 管理(确认流 two-tool,D-D3):create_invitation / approve_join_request / assign_roles
  - 内置:confirm_operation / cancel_operation

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

  # 成员管理三工具(#240):工具面 12 → 15(读列表 + 确认流批加入/改角色,Owner/Admin 专属)
  component(Cgc2046.Mcp.Tools.ListJoinRequests)
  component(Cgc2046.Mcp.Tools.ApproveJoinRequest)
  component(Cgc2046.Mcp.Tools.AssignRoles)
  component(Cgc2046.Mcp.Tools.ConfirmOperation)
  component(Cgc2046.Mcp.Tools.CancelOperation)
  # 课程 issue 学习闭环(切片 H U3,#180):工具面 8 → 12
  component(Cgc2046.Mcp.Tools.GetCourseContent)
  component(Cgc2046.Mcp.Tools.GetLearningRecords)
  component(Cgc2046.Mcp.Tools.SaveLearningRecords)
  component(Cgc2046.Mcp.Tools.SaveCourseContent)
  # 公开浏览(U2,#293):工具面 15 → 17(membership: :public 新豁免家族,KTD3)
  component(Cgc2046.Mcp.Tools.ListPublicOfferings)
  component(Cgc2046.Mcp.Tools.GetPublicOffering)
  # 角色工作台基座(role-agent-journeys-v2 S1,R2/R3/R8):工具面 17 → 20
  component(Cgc2046.Mcp.Tools.ListMyWorkspaces)
  component(Cgc2046.Mcp.Tools.GetRolePlaybook)
  component(Cgc2046.Mcp.Tools.ListMyTasks)
end
