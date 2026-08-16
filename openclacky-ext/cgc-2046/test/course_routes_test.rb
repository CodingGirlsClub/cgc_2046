# frozen_string_literal: true

# U9 课程学习面板 loopback 路由测试(plan 001/#180 R15):
# - 三端点注册与透传 JSON 形状(MCP registry call_tool 透传)
# - 未连接态(registry 未配置 cgc-2046)→ 503 + 引导信息
# - workspace_id 缺失 → 400
# - 面板 view.js 结构静态断言(三态行/当前卡/CTA/未连接态标记)
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/course_routes_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/mcp/client")

require_relative "../api/handler"

class CourseRoutesTest < Minitest::Test
  WS = "ws-uuid-1"
  COURSE = "course-uuid-1"

  # 可配置/不可配置 registry fake;call_tool 记录参数并返回 MCP content 形状
  class FakeRegistry
    attr_reader :calls

    def initialize(configured: true, result: nil, error: nil)
      @configured = configured
      @result = result
      @error = error
      @calls = []
    end

    def configured?(_name)
      @configured
    end

    def call_tool(server, tool, args)
      @calls << [server, tool, args]
      raise @error if @error

      @result || { "content" => [{ "type" => "text", "text" => JSON.generate({ "records" => [] }) }] }
    end
  end

  class FakeServer
    def initialize(registry)
      @registry = registry
    end

    private

    def mcp_registry
      @registry
    end
  end

  FakeReq = Struct.new(:body, :query)

  def build(registry:, query: {})
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(nil, query))
    # 宿主真实路径把 route params + query 合并注入 @params;测试同构
    inst.instance_variable_set(:@params, query)
    inst.instance_variable_set(:@http_server, registry && FakeServer.new(registry))
    inst
  end

  def invoke(method, pattern, inst)
    route = Cgc2046Ext.routes.find { |r| r.method == method && r.pattern == pattern }
    refute_nil route, "route #{method} #{pattern} 未注册"
    assert_raises(Clacky::ApiExtension::Halt) { inst.instance_exec(&route.block) }
  end

  # ---- 路由注册 ----

  def test_course_routes_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }
    assert_includes routes, [:get, "/courses"]
    assert_includes routes, [:get, "/courses/:course_id/content"]
    assert_includes routes, [:get, "/courses/:course_id/records"]
  end

  # ---- 透传 JSON(plan U9 场景 2) ----

  def test_courses_transfers_get_learning_records
    payload = { "records" => [{ "course_id" => COURSE, "issue_id" => "i1", "item_id" => "c1", "done" => true }] }
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(payload) }] })

    halt = invoke(:get, "/courses", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "get_learning_records", body["tool"]
    assert_equal payload, body["result"]
    assert_equal [["cgc-2046", "get_learning_records", { "workspace_id" => WS }]], registry.calls
  end

  def test_content_transfers_get_course_content
    content = { "goals" => ["g"], "issues" => [{ "id" => "i1", "kind" => "handwork", "title" => "t", "story" => {} }] }
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate({ "course_id" => COURSE, "goals" => content["goals"], "issues" => content["issues"] }) }] })

    halt = invoke(:get, "/courses/:course_id/content",
                  build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_course_content", body["tool"]
    assert_equal COURSE, body["result"]["course_id"]
    assert_equal "handwork", body["result"]["issues"][0]["kind"]
    assert_equal({ "workspace_id" => WS, "course_id" => COURSE }, registry.calls[0][2])
  end

  def test_records_transfers_filtered_query
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate({ "records" => [] }) }] })

    halt = invoke(:get, "/courses/:course_id/records",
                  build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }))

    assert_equal 200, halt.status
    assert_equal({ "workspace_id" => WS, "course_id" => COURSE }, registry.calls[0][2])
    assert_equal "get_learning_records", JSON.parse(halt.payload)["tool"]
  end

  # ---- 未连接态(plan U9 场景 2 后半) ----

  def test_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/courses", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_no_http_server_503
    halt = invoke(:get, "/courses", build(registry: nil, query: { "workspace_id" => WS }))

    assert_equal 503, halt.status
  end

  # ---- workspace_id 必填(D12 透传前置) ----

  def test_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses", build(registry: registry, query: {}))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/courses", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end
end

# ---- 面板 view.js 结构静态断言(plan U9 场景 1/3 的可测面;DOM 级留手动冒烟) ----

class CoursePanelViewTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))

  def test_panel_registers_workspace
    assert_includes VIEW, 'Clacky.ext.ui.registerWorkspace'
    assert_includes VIEW, '"cgc-2046-course"'
  end

  def test_panel_renders_three_state_rows_and_current_card
    # 三态行(plan 场景 1)
    assert_includes VIEW, 'data-testid="panel-issue-done"'
    assert_includes VIEW, 'data-testid="panel-issue-progress"'
    assert_includes VIEW, 'data-testid="panel-issue-todo"'
    # 当前 issue 卡字段:goal/given/materials/checklist 打勾态
    assert_includes VIEW, 'data-testid="panel-issue-card"'
    assert_includes VIEW, "story.goal"
    assert_includes VIEW, "story.given"
    assert_includes VIEW, "story.materials"
    assert_includes VIEW, 'data-testid="panel-check-item"'
    assert_includes VIEW, "data-done"
  end

  def test_session_launch_cta_and_prompt
    # 唤起(Rsk3 降级):复制任务指令
    assert_includes VIEW, 'data-testid="panel-cta"'
    assert_includes VIEW, "和导师学这一节"
    assert_includes VIEW, "clipboard.writeText"
    assert_includes VIEW, "八步循环"
    # H2/H3:指令用 course_title + issue.key(非内部 id 原文/goals 拼接)
    assert_includes VIEW, "content.course_title"
    assert_includes VIEW, "issue.key"
    refute_includes VIEW, "goals.join"
  end

  def test_issue_rows_render_key
    # H2:issue 行渲染展示层 key 短码
    assert_includes VIEW, "cgc-issue-key"
  end

  def test_not_connected_guidance_view
    assert_includes VIEW, 'data-testid="panel-not-connected"'
    assert_includes VIEW, "503"
  end

  def test_panel_is_read_only
    # 纯视图零写操作:不得出现写工具调用(写回发生在 session)
    refute_includes VIEW, "save_learning_records"
    refute_includes VIEW, "save_course_content"
    refute_match(/method:\s*["'](?:POST|PUT|DELETE|PATCH)["']/, VIEW)
  end
end
