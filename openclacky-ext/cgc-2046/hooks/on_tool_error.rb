# frozen_string_literal: true

# CGC-2046 扩展 hook：工具调用失败且错误与 CGC MCP 连接相关时，
# 向 WebUI 推 `ext.cgc-2046.mcp_error` 事件（persist: false，实时提示），
# 面板据此显示连接异常横幅并引导用户重新走 cgc2046-onboarding。
#
# 事件: on_tool_error —— 宿主回调签名 (call, error, agent)
#   （agent.rb: @hooks.trigger(:on_tool_error, call, e)，工具调用抛异常后触发；
#     MCP server 未配置 / 401 / 连接拒绝等都会落在这里）
#
# 判定只认 CGC MCP 具体形态（server 条目名 / 联调端点），不用裸端口/路径词，
# 其余无关错误不打扰用户。错误文本截断 + 抹凭证，防泄漏进前端。

require_relative "credential"

module Cgc2046HookError
  HINTS = /cgc-2046|localhost:4102|MCP server 'cgc/i

  # @param msg [String] 原始错误文本
  # @return [String] 截断 + 脱敏后的展示文本（≤300 字符）
  def self.redact(msg)
    msg.gsub(Cgc2046HookCredential::PATTERN, "<redacted>").slice(0, 300)
  end
end

Clacky::ExtensionHookRegistry.add do |call, error, agent|
  msg = error.respond_to?(:message) ? error.message.to_s : error.to_s
  next unless msg.match?(Cgc2046HookError::HINTS)

  agent&.emit_event(
    "ext.cgc-2046.mcp_error",
    persist: false,
    tool: call && call[:name],
    error: Cgc2046HookError.redact(msg)
  )
end
