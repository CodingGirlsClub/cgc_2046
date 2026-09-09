# frozen_string_literal: true

# before_tool_use 确认守门 hook 测试：模拟宿主加载流程（loader 设置
# current_event → require 文件 → 注册回调进 ExtensionHookRegistry），
# 取回回调后用 fake agent + fake UI 断言拦截/放行行为。
#
# 运行（需项目 mise 环境）：cd openclacky-ext/cgc-2046 && mise exec -- ruby test/before_tool_use_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/hook_loader.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/agent/hook_manager.rb")

HOOKS_DIR = File.expand_path("../hooks", __dir__)

# 模拟 ExtensionHookLoader#load_all 的加载上下文（current_event 设置 → require → 清理）
def load_hook(event, file)
  Clacky::ExtensionHookRegistry.current_event = event
  require File.join(HOOKS_DIR, file)
ensure
  Clacky::ExtensionHookRegistry.current_event = nil
end

class FakeUi
  attr_reader :confirmations

  def initialize(result)
    @result = result
    @confirmations = []
  end

  def request_confirmation(message, default: true)
    @confirmations << { message: message, default: default }
    @result
  end
end

class FakeAgent
  def initialize(ui: nil)
    @ui = ui
  end
end

# VirtualSkill 模板的标准 curl 形态（单引号 JSON body）
def curl_call(tool:, pending_id: "9f1c2a3b-1111-2222-3333-abcdef012345")
  body = { tool: tool, arguments: { pending_id: pending_id } }.to_json
  %(curl -s -X POST "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/mcp/cgc-2046/call" ) +
    %(-H "Content-Type: application/json" -d '#{body}')
end

class ConfirmGuardHookTest < Minitest::Test
  def setup
    load_hook(:before_tool_use, "before_tool_use.rb")
    @hook = Clacky::ExtensionHookRegistry.callbacks[:before_tool_use].last
    @ui = FakeUi.new(true)
    @agent = FakeAgent.new(ui: @ui)
  end

  def trigger(call, agent: @agent)
    @hook.call(call, agent)
  end

  # ── 命中：confirm_operation 弹原生确认框 ────────────────────────────

  def test_confirm_operation_prompts_native_confirmation
    result = trigger({ name: "terminal", arguments: { command: curl_call(tool: "confirm_operation") } })

    assert_equal 1, @ui.confirmations.size
    conf = @ui.confirmations.first
    assert_equal false, conf[:default], "超时必须 fail-closed（default: false）"
    assert_includes conf[:message], "pending_id: 9f1c2a3b-1111-2222-3333-abcdef012345"
    assert_equal({ action: :allow }, result, "用户批准后放行原 curl")
  end

  def test_user_denial_blocks_with_reason_for_llm
    @ui = FakeUi.new(false)
    result = trigger(
      { name: "terminal", arguments: { command: curl_call(tool: "confirm_operation") } },
      agent: FakeAgent.new(ui: @ui)
    )

    assert_equal :deny, result[:action]
    assert_includes result[:reason], "拒绝"
    assert_includes result[:reason], "请勿重试", "reason 须抑制 LLM 立即重试轰炸弹窗"
  end

  def test_timeout_nil_result_denies
    @ui = FakeUi.new(nil)
    result = trigger(
      { name: "terminal", arguments: { command: curl_call(tool: "confirm_operation") } },
      agent: FakeAgent.new(ui: @ui)
    )

    assert_equal :deny, result[:action], "超时/取消（nil）视同拒绝"
  end

  def test_double_quote_escaped_body_matches
    command = %(curl -s -X POST "http://localhost:4100/api/mcp/cgc-2046/call" -d "{\\"tool\\":\\"confirm_operation\\",\\"arguments\\":{\\"pending_id\\":\\"abcd1234-0000\\"}}")
    result = trigger({ name: "terminal", arguments: { command: command } })

    assert_equal 1, @ui.confirmations.size
    assert_includes @ui.confirmations.first[:message], "abcd1234-0000"
    assert_equal({ action: :allow }, result)
  end

  def test_spaced_json_colon_matches
    command = %(curl -s -X POST "http://localhost:4100/api/mcp/cgc-2046/call" -d '{ "tool": "confirm_operation", "arguments": { "pending_id": "aaaa1111-bbbb" } }')
    result = trigger({ name: "terminal", arguments: { command: command } })

    assert_equal 1, @ui.confirmations.size
    assert_equal({ action: :allow }, result)
  end

  def test_arguments_as_json_string_supported
    call = { name: "terminal", arguments: { command: curl_call(tool: "confirm_operation") }.to_json }
    result = trigger(call)

    assert_equal 1, @ui.confirmations.size
    assert_equal({ action: :allow }, result)
  end

  # ── 放行：非守护形态不弹窗、不改变现状 ──────────────────────────────

  def test_refund_order_first_phase_not_guarded
    result = trigger({ name: "terminal", arguments: { command: curl_call(tool: "refund_order") } })

    assert_empty @ui.confirmations, "业务工具第一段（建 pending，无副作用）不拦"
    assert_equal({ action: :allow }, result)
  end

  def test_cancel_operation_not_guarded
    result = trigger({ name: "terminal", arguments: { command: curl_call(tool: "cancel_operation") } })

    assert_empty @ui.confirmations
    assert_equal({ action: :allow }, result)
  end

  def test_tools_listing_not_guarded
    command = %(curl -s "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/mcp/cgc-2046/tools")
    result = trigger({ name: "terminal", arguments: { command: command } })

    assert_empty @ui.confirmations
    assert_equal({ action: :allow }, result)
  end

  def test_unrelated_terminal_command_passes
    result = trigger({ name: "terminal", arguments: { command: "ls -la" } })

    assert_empty @ui.confirmations
    assert_equal({ action: :allow }, result)
  end

  def test_non_terminal_tool_passes
    result = trigger({ name: "invoke_skill", arguments: { skill_name: "mcp:cgc-2046", task: "调用 confirm_operation" } })

    assert_empty @ui.confirmations, "invoke_skill 的 task 文本不是协议值，不做文本匹配"
    assert_equal({ action: :allow }, result)
  end

  def test_no_ui_agent_passes_headless
    result = trigger(
      { name: "terminal", arguments: { command: curl_call(tool: "confirm_operation") } },
      agent: FakeAgent.new(ui: nil)
    )

    assert_equal({ action: :allow }, result, "无 UI 的 headless 场景不替宿主加锁（后端 pending 仍是防线）")
  end

  def test_malformed_arguments_pass
    result = trigger({ name: "terminal", arguments: "not-json{{{" })

    assert_empty @ui.confirmations
    assert_equal({ action: :allow }, result)
  end

  def test_confirm_operation_without_pending_id_still_guarded
    command = %(curl -s -X POST "http://localhost:4100/api/mcp/cgc-2046/call" -d '{"tool":"confirm_operation"}')
    result = trigger({ name: "terminal", arguments: { command: command } })

    assert_equal 1, @ui.confirmations.size, "缺 pending_id 仍是点火动作，必须拦"
    refute_includes @ui.confirmations.first[:message], "pending_id:", "无 id 时文案不带空括号"
    assert_equal({ action: :allow }, result)
  end
end
