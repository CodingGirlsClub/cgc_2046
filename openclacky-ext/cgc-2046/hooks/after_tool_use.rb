# frozen_string_literal: true

# CGC-2046 扩展 hook：主 agent 每次调用 CGC MCP server 后推事件（面板「最近活动」区）。
#
# 事件: after_tool_use —— 宿主回调签名 (call, result, agent)
#   （agent.rb: @hooks.trigger(:after_tool_use, call, result)，任何工具调用后触发）
#
# CGC MCP server 在 agent 侧是 virtual skill（registry.rb VirtualSkill，fork
# subagent 经 curl 调本地 HTTP API），主 agent 层只看到一次 invoke_skill 调用，
# 因此事件粒度 = 每次 CGC MCP 使用边界，不刷屏。
#
# server 条目名统一为 `cgc-2046`（D14：扩展 id / MCP server 条目名 / 本地技能前缀统一）。
#
# 错误判定：subagent 内的 curl 调用失败不会抛 Ruby 异常（terminal 工具成功返回
# 文本），连接错误藏在 subagent summary 里 —— 在这里做文本特征判定，命中则推
# `ext.cgc-2046.mcp_error`（面板连接异常横幅 + 引导重新 onboarding）。
#
# 成功事件 persist: true（里程碑，刷新后仍在消息流）；失败 persist: false。

require_relative "credential"

module Cgc2046HookUse
  SKILL_NAMES = ["mcp:cgc-2046"].freeze

  # CGC MCP 连接失败具体形态（host 不可达 / 未配置 / 鉴权失败）；
  # 用具体形态而非裸词（裸 "not configured"/"HTTP 401" 会误伤无关 subagent 文本）
  MCP_ERROR_PATTERN = /MCP server 'cgc|Connection refused|Failed to open TCP|localhost:4102/i

  # @param result [Object] invoke_skill 的返回
  # @return [Boolean] 工具层是否成功（无 error 键即成功；subagent 正常结束即成功）
  def self.ok?(result)
    !(result.is_a?(Hash) && (result[:error] || result["error"]))
  end

  # @param result [Hash] invoke_skill 的返回
  # @return [String] subagent summary 文本（无则空串）
  def self.summary(result)
    return "" unless result.is_a?(Hash)

    (result[:result] || result["result"]).to_s
  end

  # @param text [String] summary 全文
  # @return [String, nil] 错误片段（匹配处前后 120 字符，抹凭证；无命中 nil）
  def self.error_snippet(text)
    m = text.match(MCP_ERROR_PATTERN)
    return nil unless m

    start_at = [m.begin(0) - 60, 0].max
    snippet = text[start_at, 240].to_s
    snippet.gsub(Cgc2046HookCredential::PATTERN, "<redacted>")
  end
end

Clacky::ExtensionHookRegistry.add do |call, result, agent|
  next unless call && call[:name] == "invoke_skill"

  skill = call.dig(:arguments, "skill_name") || call.dig(:arguments, :skill_name)
  next unless Cgc2046HookUse::SKILL_NAMES.include?(skill)

  ok = Cgc2046HookUse.ok?(result)
  agent&.emit_event(
    "ext.cgc-2046.tool_used",
    persist: ok,
    tool: skill,
    status: ok ? "ok" : "error"
  )

  # 工具层成功但 subagent 实际连不上 CGC MCP —— 这是用户最需要引导的场景
  snippet = Cgc2046HookUse.error_snippet(Cgc2046HookUse.summary(result))
  if ok && snippet
    agent&.emit_event(
      "ext.cgc-2046.mcp_error",
      persist: false,
      tool: skill,
      error: snippet
    )
  end
end
