# frozen_string_literal: true

# CGC-2046 工作台数据面(role-agent-journeys-v2 S1-extension):身份上下文三路由的
# loopback 透传——
#   GET /me/workspaces → list_my_workspaces(可访问 Workspace 列表 + 角色 + is_platform_admin)
#   GET /playbook      → get_role_playbook(角色工作模式;role 必填,workspace_id 可选)
#   GET /tasks         → list_my_tasks(本人待办;workspace_id 必填)
# 必填参数校验在 handler 层(400 引导),本模块只做 registry 透传。
#
# 管道(connected_registry / normalize_mcp_result / 503·502·500 错误分层)
# 委托 Cgc2046CourseRoutes.call_tool,仅 503 引导文案与 500 前缀指向工作台。
#
# 安全红线:token 只存在于 mcp.json(由 connect 端点管理);本模块不读
# token、不把凭证写进响应或日志。

module Cgc2046WorkbenchRoutes
  NOT_CONNECTED = {
    error: "cgc-2046 MCP server not connected",
    hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用工作台功能"
  }.freeze

  module_function

  # MCP 工作台工具 → loopback JSON 形状:{ ok: true, tool: ..., result: ... }
  # 错误分层同 course_routes:未连接 503 / 上游 McpError 502 / 意外 500。
  def call_workbench_tool(handler, tool_name, arguments)
    Cgc2046CourseRoutes.call_tool(handler, tool_name, arguments,
                                  not_connected: NOT_CONNECTED, error_prefix: "workbench route failed")
  end
end
