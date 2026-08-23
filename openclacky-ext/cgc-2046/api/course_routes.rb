# frozen_string_literal: true

# CGC-2046 课程学习面板的 loopback 数据面(U9,plan 001 / #180 R15)。
#
# 面板是纯视图:fetch 本模块路由 → 本模块经宿主 MCP registry 透传平台工具
# (dsh-cgc-core 已验证的 routes + MCP client 封装形态;宿主能力 =
# Clacky::Mcp::Registry#call_tool(server_name, tool_name, arguments))。
# 不做任何写操作(学习记录写回发生在 session 的工具调用)。
#
# 安全红线:token 只存在于 mcp.json(由 connect 端点管理);本模块不读
# token、不把凭证写进响应或日志。未连接(registry 无 cgc-2046)→ 503 +
# 引导信息(面板据此渲染未连接态)。

require "json"

module Cgc2046CourseRoutes
  SERVER_NAME = "cgc-2046"
  NOT_CONNECTED = {
    error: "cgc-2046 MCP server not connected",
    hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用课程学习面板"
  }.freeze

  module_function

  # registry 可用且已配置 cgc-2046 才透传
  def connected_registry(handler)
    registry = handler.instance_variable_get(:@http_server)&.send(:mcp_registry)
    return nil unless registry&.configured?(SERVER_NAME)

    registry
  rescue StandardError
    nil
  end

  # MCP 工具调用管道:connected_registry → call_tool → 200 包装;错误分层:
  # 未连接 503(各面板自带 not_connected 引导文案)/ 上游 McpError 502 /
  # 意外 500(error_prefix 区分面板)。offering 数据面整体委托本函数
  # (call_offering_tool 单行转发,仅 not_connected 文案与 error_prefix 不同)。
  def call_tool(handler, tool_name, arguments, not_connected:, error_prefix:)
    registry = connected_registry(handler)
    return { status: 503, body: not_connected } unless registry

    result = registry.call_tool(SERVER_NAME, tool_name, arguments)
    { status: 200, body: { ok: true, tool: tool_name, result: normalize_mcp_result(result) } }
  rescue Clacky::Mcp::Client::McpError => e
    { status: 502, body: { error: "MCP call failed: #{e.message}" } }
  rescue StandardError => e
    { status: 500, body: { error: "#{error_prefix}: #{e.message}" } }
  end

  # MCP 工具结果 → loopback JSON 形状:{ ok: true, tool: ..., result: ... }
  def call_course_tool(handler, tool_name, arguments)
    call_tool(handler, tool_name, arguments,
              not_connected: NOT_CONNECTED, error_prefix: "course route failed")
  end

  # 宿主 client 返回形态收敛:content 数组取 text 拼接后 JSON 解析(失败原样)
  def normalize_mcp_result(result)
    content = result.is_a?(Hash) ? result["content"] : nil
    texts = Array(content).filter_map { |c| c.is_a?(Hash) ? c["text"] : nil }
    return result if texts.empty?

    JSON.parse(texts.join)
  rescue JSON::ParserError
    texts.join
  end
end
