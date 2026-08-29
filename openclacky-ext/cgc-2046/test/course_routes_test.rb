# frozen_string_literal: true

# U9 课程学习面板 loopback 路由测试(plan 001/#180 R15;S4-extension 加草稿写回):
# - 三读端点注册与透传 JSON 形状(MCP registry call_tool 透传)
# - 未连接态(registry 未配置 cgc-2046)→ 503 + 引导信息
# - workspace_id 缺失 → 400
# - 面板 view.js 结构静态断言(三态行/当前卡/CTA/未连接态标记)
# - 写面纪律:面板唯一写操作 = 草稿保存(POST content → save_course_content);
#   学习记录写回仍只发生在 session(写面收窄断言,409/编辑断言在
#   course_content_write_test.rb)
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

  FakeReq = Struct.new(:body, :query, :header) do
    def headers
      header || {}
    end
  end

  # 宿主真实形态(openclacky-1.5.9 dispatcher,smoke01 #1 实证):
  #   @params = route pattern captures(symbol key,如 :course_id)
  #   GET query 在 req.query(WEBrick),不进 @params
  # params 默认 {} = 无 route capture 的 /courses 路径真实形态。
  # advisor F2:写路由的面板同款头（json Content-Type + CSRF token）
  def write_headers
    { "Content-Type" => "application/json", "X-CGC-CSRF-Token" => Cgc2046Ext.csrf_token }
  end

  def build(registry:, query: {}, params: {}, header: {})
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(nil, query, {}))
    inst.instance_variable_set(:@params, params)
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
        assert_includes routes, [:get, "/courses/:course_id/content"]
    assert_includes routes, [:get, "/courses/:course_id/prep"]
  end

  # ---- 透传 JSON(plan U9 场景 2) ----

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

  # S5-extension:教研状态透传(get_prep_status;workspace_id query 合并同 course_tool)
  def test_prep_transfers_get_prep_status
    prep = { "course_id" => COURSE, "prep_state" => "authoring",
             "policy" => { "review_required" => true, "quality_threshold" => 80, "reviewer_user_id" => nil },
             "assignee_user_id" => "u-1", "latest_quality_report" => nil,
             "gate_violations" => [], "version" => 3 }
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(prep) }] })

    halt = invoke(:get, "/courses/:course_id/prep",
                  build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_prep_status", body["tool"]
    assert_equal "authoring", body["result"]["prep_state"]
    assert_equal({ "workspace_id" => WS, "course_id" => COURSE }, registry.calls[0][2])
  end

  # ---- 未连接态(plan U9 场景 2 后半) ----

  def test_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/courses/:course_id/content", build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_no_http_server_503
    halt = invoke(:get, "/courses/:course_id/content", build(registry: nil, query: { "workspace_id" => WS, "course_id" => COURSE }))

    assert_equal 503, halt.status
  end

  # ---- route_params_value 三层兜底(smoke01 #1 回归)----
  # 真实宿主:GET query 不进 @params,workspace_id 只在 req.query → 必须仍 200
  def test_workspace_id_via_query_when_params_empty
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses/:course_id/content", build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }, params: {}))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "get_course_content", { "workspace_id" => WS, "course_id" => COURSE }]], registry.calls
  end

  # 真实宿主 dispatcher 注入 symbol key route captures(:course_id)
  def test_course_id_via_symbol_route_capture
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses/:course_id/content",
                  build(registry: registry, query: { "workspace_id" => WS }, params: { course_id: COURSE }))

    assert_equal 200, halt.status
    assert_equal({ "workspace_id" => WS, "course_id" => COURSE }, registry.calls[0][2])
  end

  # string key @params(测试 allocate 同构注入的历史形态)仍兼容
  def test_course_id_via_string_params
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses/:course_id/content",
                  build(registry: registry, query: { "workspace_id" => WS }, params: { "course_id" => COURSE }))

    assert_equal 200, halt.status
    assert_equal({ "workspace_id" => WS, "course_id" => COURSE }, registry.calls[0][2])
  end

  # params 与 query 双空 → 400 引导(workspace_id 必填)
  def test_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses/:course_id/content", build(registry: registry, query: {}, params: {}))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/courses/:course_id/content", build(registry: registry, query: { "workspace_id" => WS, "course_id" => COURSE }))

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

  def test_panel_renders_objective_map_and_next_action
    # S8:objective 四态地图(S8 全量替换 issue 三态行/当前卡)
    assert_includes VIEW, 'data-testid="panel-obj-row"'
    assert_includes VIEW, 'data-testid="panel-obj-badge"'
    assert_includes VIEW, 'masteryLabel'
    assert_includes VIEW, "已掌握"
    assert_includes VIEW, "学习中"
    assert_includes VIEW, "待复习"
    assert_includes VIEW, "未学"
    assert_includes VIEW, 'data-testid="panel-obj-locked"'
    assert_includes VIEW, 'data-testid="panel-next-action"'
    assert_includes VIEW, 'data-testid="panel-progress"'
    assert_includes VIEW, 'data-testid="panel-stale"'
    # 旧 issue 三态/checklist 学习语义已删
    refute_includes VIEW, 'data-testid="panel-issue-done"'
    refute_includes VIEW, 'data-testid="panel-issue-card"'
    refute_includes VIEW, 'data-testid="panel-check-item"'
  end

  def test_not_connected_guidance_view
    assert_includes VIEW, 'data-testid="panel-not-connected"'
    assert_includes VIEW, "503"
  end

  def test_not_connected_retry_entry
    # smoke01 #2:引导视图显式重试入口(loadCourses 重探 loopback)
    assert_includes VIEW, 'data-testid="panel-retry"'
    assert_includes VIEW, "#cgc-retry"
  end

  def test_session_launch_cta_and_prompt
    # S8 唤起(Rsk3 降级):复制 objective 口径任务指令
    assert_includes VIEW, 'data-testid="panel-cta"'
    assert_includes VIEW, "clipboard.writeText"
    assert_includes VIEW, "七步学习循环"
    assert_includes VIEW, "submit_learning_attempt"
    assert_includes VIEW, "objective_id"
    assert_includes VIEW, "content.course_title"
    refute_includes VIEW, "八步循环"
    refute_includes VIEW, "goals.join"
  end

  def test_panel_uses_learning_state_source
    # S8:详情主数据源 /learning_state + /revision 展示增强
    assert_includes VIEW, '"/learning_state?workspace_id="'
    assert_includes VIEW, '"/revision"'
    refute_includes VIEW, '"/records"'
  end

  def test_not_connected_guidance_view
    assert_includes VIEW, 'data-testid="panel-not-connected"'
    assert_includes VIEW, "503"
  end

  def test_panel_write_surface_is_draft_save_only
    # S4 起面板唯一写操作 = 课程草稿保存(save_course_content,经 loopback
    # POST /courses/:course_id/content);学习记录写回仍只发生在 session 工具调用
    refute_includes VIEW, "save_learning_records"
    # 面板不直连 MCP 写工具名之外的回写通道;唯一 POST 面 = 草稿保存路由
    assert_includes VIEW, '"/courses/" + encodeURIComponent(courseId) + "/content"'
    refute_match(/method:\s*["'](?:PUT|DELETE|PATCH)["']/, VIEW)
  end

  def test_panel_prep_section_structure
    # S5-extension:canEdit 详情页教研流程状态区(prep_state badge / 违规清单 /
    # 最新质量报告);仅读透传 get_prep_status,无写操作
    assert_includes VIEW, 'data-testid="panel-prep"'
    assert_includes VIEW, 'data-testid="panel-prep-state"'
    assert_includes VIEW, 'data-testid="panel-prep-violations"'
    assert_includes VIEW, 'data-testid="panel-prep-quality"'
    assert_includes VIEW, '"/courses/" + encodeURIComponent(courseId) + "/prep"'
    # 存量课程无 prep run 按 null 处理(不置 state.error)
    assert_includes VIEW, "state.prep = null"
    refute_includes VIEW, "approve_prep"
  end
end
