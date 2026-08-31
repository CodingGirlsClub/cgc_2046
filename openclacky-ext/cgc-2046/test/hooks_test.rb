# frozen_string_literal: true

# hook 文件测试：模拟宿主加载流程（loader 设置 current_event → require 文件 →
# 注册回调进 ExtensionHookRegistry），取回回调后用 fake agent 断言行为。
#
# 运行（需项目 mise 环境）：cd openclacky-ext/cgc-2046 && mise exec -- ruby test/hooks_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/hook_loader.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/agent/hook_manager.rb")

HOOKS_DIR = File.expand_path("../hooks", __dir__)

class FakeAgent
  attr_reader :emitted

  def initialize
    @emitted = []
  end

  def emit_event(type, persist:, **data)
    @emitted << { type: type, persist: persist, data: data }
  end
end

# 模拟 ExtensionHookLoader#load_all 的加载上下文（current_event 设置 → require → 清理）
def load_hook(event, file)
  Clacky::ExtensionHookRegistry.current_event = event
  require File.join(HOOKS_DIR, file)
ensure
  Clacky::ExtensionHookRegistry.current_event = nil
end

class OnToolErrorHookTest < Minitest::Test
  def setup
    load_hook(:on_tool_error, "on_tool_error.rb")
    @hook = Clacky::ExtensionHookRegistry.callbacks[:on_tool_error].last
    @agent = FakeAgent.new
  end

  def trigger(error)
    @hook.call({ name: "terminal" }, error, @agent)
  end

  def test_emits_mcp_error_on_not_configured_message
    err = RuntimeError.new("MCP server 'cgc-2046' is not configured")
    trigger(err)

    assert_equal 1, @agent.emitted.size
    ev = @agent.emitted.first
    assert_equal "ext.cgc-2046.mcp_error", ev[:type]
    assert_equal false, ev[:persist], "连接错误是实时提示，不得持久化"
    assert_equal "terminal", ev[:data][:tool]
    assert_includes ev[:data][:error], "not configured"
  end

  def test_emits_on_http_401_from_server
    err = RuntimeError.new("HTTP 401 from MCP server 'cgc-2046': unauthorized")
    trigger(err)

    assert_equal 1, @agent.emitted.size
    assert_equal "ext.cgc-2046.mcp_error", @agent.emitted.first[:type]
  end

  def test_emits_on_curl_connection_failure_to_mcp_endpoint
    # 真实形态（实测）：MCP server 初始化失败文本含端点与 server 名
    err = RuntimeError.new("MCP server 'cgc-2046' error on initialize: " \
                           "HTTP transport error: Failed to open TCP connection to localhost:4102 (Connection refused)")
    trigger(err)

    assert_equal 1, @agent.emitted.size
    assert_includes @agent.emitted.first[:data][:error], "Failed to open TCP"
  end

  def test_silent_on_unrelated_port_number_text
    # 收紧后：裸端口/路径词不再触发（漏报优于误报）
    trigger(RuntimeError.new("Error at line 4102 in parser"))
    trigger(RuntimeError.new("Failed to call /mcp/other-server/tools"))

    assert_empty @agent.emitted
  end

  def test_silent_on_unrelated_errors
    trigger(RuntimeError.new("No such file or directory @ rb_sysopen"))
    trigger(ArgumentError.new("unknown keyword"))

    assert_empty @agent.emitted
  end

  def test_redacts_bearer_tokens_from_error_text
    err = RuntimeError.new("HTTP 401 from MCP server 'cgc-2046': Authorization: Bearer tok_abc123 secret")
    trigger(err)

    ev = @agent.emitted.first
    refute_includes ev[:data][:error], "tok_abc123", "错误文本中的 Bearer 凭证必须被抹掉"
    assert_includes ev[:data][:error], "<redacted>"
  end

  def test_redacts_prose_token_with_cgc_prefix
    # LLM 散文转述形态（无 "Bearer " 前缀）也必须脱敏
    err = RuntimeError.new("MCP server 'cgc-2046' failed: token 是 cgc_YWyY0WdE_jLf8NkbhPRfAU-mz0xaOTZ4sHLS_5x8c2c 存在 mcp.json 里")
    trigger(err)

    ev = @agent.emitted.first
    refute_includes ev[:data][:error], "cgc_YWyY0WdE", "散文转述的 cgc_ token 必须被抹掉"
    assert_includes ev[:data][:error], "<redacted>"
  end

  def test_redacts_base64_tail_characters
    err = RuntimeError.new("Authorization: Bearer abc+def/ghi= failed for cgc-2046")
    trigger(err)

    ev = @agent.emitted.first
    refute_includes ev[:data][:error], "def/ghi", "base64 的 +/= 尾部不得泄漏"
    assert_includes ev[:data][:error], "<redacted>"
  end

  def test_truncates_long_error_text
    err = RuntimeError.new("MCP server 'cgc-2046' error: " + "x" * 2000)
    trigger(err)

    assert_operator @agent.emitted.first[:data][:error].length, :<=, 300
  end

  def test_accepts_error_objects_without_message
    trigger("MCP server 'cgc-2046' is not configured")

    assert_equal 1, @agent.emitted.size
  end
end

class AfterToolUseHookTest < Minitest::Test
  def setup
    load_hook(:after_tool_use, "after_tool_use.rb")
    @hook = Clacky::ExtensionHookRegistry.callbacks[:after_tool_use].last
    @agent = FakeAgent.new
  end

  def trigger(call, result)
    @hook.call(call, result, @agent)
  end

  def test_emits_tool_used_on_successful_cgc_mcp_call
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046", "task" => "查工作台" } },
            { "message" => "ok" })

    assert_equal 1, @agent.emitted.size
    ev = @agent.emitted.first
    assert_equal "ext.cgc-2046.tool_used", ev[:type]
    assert_equal true, ev[:persist], "成功调用是里程碑事件，应持久化"
    assert_equal "mcp:cgc-2046", ev[:data][:tool]
    assert_equal "ok", ev[:data][:status]
  end

  def test_emits_mcp_error_when_subagent_summary_reports_connection_failure
    # 真实路径：subagent 内 curl 失败不抛异常，错误文本进 subagent summary
    summary = "调用 get_workspace_context 失败：MCP server 'cgc-2046' error on initialize: " \
              "HTTP transport error: Failed to open TCP connection to localhost:4102 (Connection refused)"
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => summary })

    assert_equal 2, @agent.emitted.size, "应同时推 tool_used 与 mcp_error"
    types = @agent.emitted.map { |e| e[:type] }.sort
    assert_equal ["ext.cgc-2046.mcp_error", "ext.cgc-2046.tool_used"], types

    err = @agent.emitted.find { |e| e[:type] == "ext.cgc-2046.mcp_error" }
    assert_equal false, err[:persist]
    assert_includes err[:data][:error], "Connection refused"
    assert_operator err[:data][:error].length, :<=, 240, "错误片段应截断"
  end

  def test_no_mcp_error_when_subagent_summary_is_clean
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => "工作台状态正常，查询完成" })

    assert_equal 1, @agent.emitted.size
    assert_equal "ext.cgc-2046.tool_used", @agent.emitted.first[:type]
  end

  def test_accepts_symbol_skill_name_key
    trigger({ name: "invoke_skill", arguments: { skill_name: "mcp:cgc-2046" } }, { "message" => "ok" })

    assert_equal 1, @agent.emitted.size
  end

  def test_silent_on_other_skills
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "cgc2046-onboarding" } }, { "message" => "ok" })
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:other-server" } }, { "message" => "ok" })

    assert_empty @agent.emitted
  end

  def test_silent_on_non_skill_tools
    trigger({ name: "terminal", arguments: { "command" => "ls" } }, { "output" => "x" })

    assert_empty @agent.emitted
  end

  def test_emits_error_status_when_result_carries_error
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "error" => "MCP call failed" })

    assert_equal 1, @agent.emitted.size, "工具层失败不推 mcp_error（无 summary 可判定）"
    ev = @agent.emitted.first
    assert_equal "ext.cgc-2046.tool_used", ev[:type]
    assert_equal "error", ev[:data][:status]
    assert_equal false, ev[:persist], "失败事件只实时提示，不持久化"
  end

  def test_redacts_bearer_tokens_in_error_snippet
    summary = "MCP server 'cgc-2046' unauthorized: Authorization: Bearer tok_secret_abc"
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => summary })

    err = @agent.emitted.find { |e| e[:type] == "ext.cgc-2046.mcp_error" }
    refute_nil err
    refute_includes err[:data][:error], "tok_secret_abc"
    assert_includes err[:data][:error], "<redacted>"
  end

  def test_redacts_prose_token_in_error_snippet
    summary = "MCP server 'cgc-2046' error: token 是 cgc_YWyY0WdE_jLf8NkbhPRfAU-mz0xaOTZ4sHLS_5x8c2c"
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => summary })

    err = @agent.emitted.find { |e| e[:type] == "ext.cgc-2046.mcp_error" }
    refute_nil err
    refute_includes err[:data][:error], "cgc_YWyY0WdE"
  end

  def test_redacts_bare_jwt_in_error_snippet
    jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    summary = "MCP server 'cgc-2046' failed, token: #{jwt}"
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => summary })

    err = @agent.emitted.find { |e| e[:type] == "ext.cgc-2046.mcp_error" }
    refute_nil err
    refute_includes err[:data][:error], "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "裸 JWT 必须脱敏"
  end

  def test_no_mcp_error_for_bare_not_configured_phrase
    # 收紧后：裸 "not configured" 不再是模式词（真实形态由 MCP server 'cgc 前缀覆盖）
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
            { "skill_type" => "subagent", "result" => "The timezone is not configured, using UTC" })

    assert_equal 1, @agent.emitted.size, "无关文本不得触发 mcp_error"
    assert_equal "ext.cgc-2046.tool_used", @agent.emitted.first[:type]
  end
end

class DraftSavedEventTest < Minitest::Test
  # P1 AI 辅助教研:save_course_content 特征命中(task 或 summary)推 draft_saved 纯信号
  def setup
    load_hook(:after_tool_use, "after_tool_use.rb")
    @hook = Clacky::ExtensionHookRegistry.callbacks[:after_tool_use].last
    @agent = FakeAgent.new
  end

  def trigger(call, result)
    @hook.call(call, result, @agent)
  end

  def test_emits_draft_saved_on_save_course_content_task
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046",
      "task" => "请 save_course_content 保存课程草稿" } },
      { "result" => "已保存" })

    ev = @agent.emitted.find { |e| e[:type] == "ext.cgc-2046.draft_saved" }
    refute_nil ev, "应推 draft_saved 信号"
    assert_equal false, ev[:persist]
  end

  def test_no_draft_saved_without_save_marker
    trigger({ name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046",
      "task" => "查询学习状态" } },
      { "result" => "正常" })

    assert @agent.emitted.none? { |e| e[:type] == "ext.cgc-2046.draft_saved" }
  end
end

class HookManagerIntegrationTest < Minitest::Test
  # 走宿主真实加载/触发路径：ExtensionHookRegistry.apply_to → HookManager.trigger
  # （验证回调参数顺序 call/error/agent 与 agent 注入机制，而非直接调块）
  def setup
    load_hook(:on_tool_error, "on_tool_error.rb")
    load_hook(:after_tool_use, "after_tool_use.rb")
    @agent = FakeAgent.new
    @manager = Clacky::HookManager.new(agent: @agent)
    Clacky::ExtensionHookRegistry.apply_to(@manager)
  end

  def test_trigger_routes_on_tool_error_with_agent_injection
    @manager.trigger(:on_tool_error,
                     { name: "terminal" },
                     RuntimeError.new("MCP server 'cgc-2046' is not configured"))

    assert_equal 1, @agent.emitted.size
    assert_equal "ext.cgc-2046.mcp_error", @agent.emitted.first[:type]
  end

  def test_trigger_routes_after_tool_use_for_cgc_skill
    @manager.trigger(:after_tool_use,
                     { name: "invoke_skill", arguments: { "skill_name" => "mcp:cgc-2046" } },
                     { "message" => "ok" })

    assert_equal 1, @agent.emitted.size
    assert_equal "ext.cgc-2046.tool_used", @agent.emitted.first[:type]
  end

  def test_trigger_silent_for_unrelated_events
    @manager.trigger(:on_tool_error, { name: "terminal" }, RuntimeError.new("boom"))
    @manager.trigger(:after_tool_use, { name: "terminal" }, { "output" => "x" })

    assert_empty @agent.emitted
  end
end

