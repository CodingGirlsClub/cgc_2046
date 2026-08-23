# frozen_string_literal: true

# CGC-2046 发现面板的 loopback 数据面(U6,R11/R12/AE5;KTD3/KTD9)。
#
# 面板是纯视图:fetch 本模块路由 → 本模块经宿主 MCP registry 透传公开浏览
# 工具(list_public_offerings / get_public_offering)。两工具 meta 为
# %{workspace_id: :optional, membership: :public}(U2,#293)——任何持连接
# token 的登录用户可调,本模块不做 workspace_id 硬要求(与 course 数据面的
# 分野:course_tool 在 handler 层注入必填校验,这里直连 registry)。
#
# 管道(connected_registry / normalize_mcp_result / 503·502·500 错误分层)
# 复用 Cgc2046CourseRoutes.call_tool,仅 503 引导文案与 500 前缀指向发现面板。
#
# 安全红线:token 只存在于 mcp.json(由 connect 端点管理);本模块不读
# token、不把凭证写进响应或日志。

require "json"

module Cgc2046OfferingRoutes
  NOT_CONNECTED = {
    error: "cgc-2046 MCP server not connected",
    hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用发现面板"
  }.freeze

  module_function

  # MCP 公开浏览工具 → loopback JSON 形状:{ ok: true, tool: ..., result: ... }
  # 错误分层同 course_routes:未连接 503 / 上游 McpError 502 / 意外 500。
  def call_offering_tool(handler, tool_name, arguments)
    registry = Cgc2046CourseRoutes.connected_registry(handler)
    return { status: 503, body: NOT_CONNECTED } unless registry

    result = registry.call_tool(Cgc2046CourseRoutes::SERVER_NAME, tool_name, arguments)
    { status: 200,
      body: { ok: true, tool: tool_name, result: Cgc2046CourseRoutes.normalize_mcp_result(result) } }
  rescue Clacky::Mcp::Client::McpError => e
    { status: 502, body: { error: "MCP call failed: #{e.message}" } }
  rescue StandardError => e
    { status: 500, body: { error: "offering route failed: #{e.message}" } }
  end
end
