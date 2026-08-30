# frozen_string_literal: true

# CGC-2046 Learner 报名/支付数据面(S7-extension,R30–R35/AE3/AE6–AE8)。
#
# 面板是纯视图:fetch 本模块路由 → 本模块经宿主 MCP registry 透传 Learner 工具
# (discover_offerings / get_enrollment_summary / create_enrollment /
# get_my_enrollments / get_order_status)。五工具合同由并行 backend 切片交付,
# 本仓按合同钉参数与错误分层:
#   - discover_offerings / get_my_enrollments 无参数(跨 workspace 合并面孔,
#     不下发 workspace_id 作用域);
#   - get_enrollment_summary / get_order_status 的必填参数在 handler 层校验(400 引导);
#   - create_enrollment 幂等:同一意图重放返回既有 enrollment(idempotent_replay),
#     永不因重复报名报错——面板确认按钮可安全重试。
#
# 管道(connected_registry / normalize_mcp_result / 503·502·500 错误分层)
# 委托 Cgc2046CourseRoutes.call_tool,仅 503 引导文案与 500 前缀指向 Learner 旅程。
#
# 安全红线:token 只存在于 mcp.json(由 connect 端点管理);本模块不读
# token、不把凭证写进响应或日志。支付凭证/SDK 永不经本模块(R33)。

module Cgc2046LearnerRoutes
  NOT_CONNECTED = {
    error: "cgc-2046 MCP server not connected",
    hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用报名/支付功能"
  }.freeze

  module_function

  # MCP Learner 工具 → loopback JSON 形状:{ ok: true, tool: ..., result: ... }
  # 错误分层同 course_routes:未连接 503 / 上游 McpError 502 / 意外 500。
  def call_learner_tool(handler, tool_name, arguments)
    Cgc2046CourseRoutes.call_tool(handler, tool_name, arguments,
                                  not_connected: NOT_CONNECTED, error_prefix: "learner route failed")
  end
end
