# frozen_string_literal: true

# CGC-2046 扩展 hook：资金/高风险确认守门（R1 加固——把 confirm 从 LLM 手里拿走）。
#
# 事件: before_tool_use —— 宿主回调签名 (call, agent)；返回
#   { action: :allow } 放行 / { action: :deny, reason: } 阻断（reason 作为工具
#   错误结果回给 LLM）。宿主 hook_manager.rb 逐钩子执行、首个 deny 短路；
#   agent.rb 在工具执行前触发，且 ExtensionHookRegistry.apply_to 在每个
#   agent 实例（含 invoke_skill fork 出的 MCP subagent）的 initialize 里
#   运行——本 hook 对 subagent 的 terminal 调用同样生效。
#
# 背景：CGC MCP 高风险写（退款/免缴等）走后端两段式确认流——agent 先调
# 业务工具建 PendingOperation（无副作用），复述摘要、用户同意后调
# confirm_operation 点火。「用户同意」此前只是会话文本，LLM 被注入诱导
# 后可自问自答完成确认。本 hook 把点火动作拦到宿主原生 UI：subagent 经
# curl POST /api/mcp/cgc-2046/call 调 confirm_operation 时（VirtualSkill
# 固定形态，body 的 tool 字段是协议级准确值，写错后端即 400），弹宿主
# request_confirmation 原生确认框——WebUI 浏览器弹窗（web_ui_controller.rb：
# ConditionVariable 阻塞等点击，5min 超时回落 default），终端 RichUI
# Approve/Deny 框。批准才放行；拒绝/超时 deny（default: false，fail-closed）。
#
# 只拦 confirm_operation（资金副作用点火器）：业务工具第一段（建 pending，
# 无副作用）与 cancel_operation（取消）不拦。命令解析不出守护形态一律放行
# （保守：不改变现状；hook 抛异常宿主 rescue 后同样视为放行）。
#
# 无 UI（headless）场景放行：后端 PendingOperation 本人确认 + TTL 仍是防线；
# 本 hook 目标是「有 UI 时把最后一步从 LLM 手里拿走」，不替 headless 加锁。

require "json"

module Cgc2046HookConfirmGuard
  CALL_PATH = "/api/mcp/cgc-2046/call"
  GUARDED_TOOL = "confirm_operation"

  # curl body 在命令文本中的 JSON 形态：单引号包裹为 "tool":"xxx"；双引号
  # 包裹经 shell 转义为 \"tool\":\"xxx\"；冒号两侧空白容忍。
  TOOL_PATTERN = /\\?"tool\\?"\s*:\s*\\?"#{GUARDED_TOOL}\\?"/
  PENDING_ID_PATTERN = /\\?"pending_id\\?"\s*:\s*\\?"([0-9A-Za-f-]{8,})\\?"/

  # @param command [String, nil] terminal 命令全文
  # @return [String, nil] 命中守护调用时返回 pending_id（取不到为空串），未命中 nil
  def self.guarded_pending_id(command)
    return nil unless command.is_a?(String)
    return nil unless command.include?(CALL_PATH)
    return nil unless command.match?(TOOL_PATTERN)

    m = command.match(PENDING_ID_PATTERN)
    m ? m[1] : ""
  end

  # @param arguments [Hash, String, nil] tool call 参数（宿主两种形态都出现）
  # @return [String, nil]
  def self.command_of(arguments)
    case arguments
    when Hash
      arguments[:command] || arguments["command"]
    when String
      begin
        parsed = JSON.parse(arguments)
        parsed.is_a?(Hash) ? (parsed[:command] || parsed["command"]) : nil
      rescue JSON::ParserError
        nil
      end
    end
  end

  # @param pending_id [String] 命中的 pending_id（可为空串）
  # @return [String] 原生确认框展示文案
  def self.confirmation_message(pending_id)
    id_part = pending_id.empty? ? "" : "（pending_id: #{pending_id}）"
    "CGC 高风险操作确认#{id_part}：助手即将执行已待确认的资金/管理写操作" \
      "（如退款/免缴）。请仅在已核对会话中助手复述的操作摘要后点确认；" \
      "拒绝或超时将取消本次执行。"
  end
end

Clacky::ExtensionHookRegistry.add do |call, agent|
  next { action: :allow } unless call && call[:name] == "terminal"

  pending_id = Cgc2046HookConfirmGuard.guarded_pending_id(
    Cgc2046HookConfirmGuard.command_of(call[:arguments] || call["arguments"])
  )
  next { action: :allow } unless pending_id

  ui = agent&.instance_variable_get(:@ui)
  next { action: :allow } unless ui && ui.respond_to?(:request_confirmation)

  approved = ui.request_confirmation(
    Cgc2046HookConfirmGuard.confirmation_message(pending_id),
    default: false
  )

  if approved == true
    { action: :allow }
  else
    {
      action: :deny,
      reason: "用户在宿主界面拒绝了本次确认操作（或确认超时）。请勿重试；" \
              "向用户如实说明该操作未被批准；如用户仍希望执行，请其明确再次确认。"
    }
  end
end
