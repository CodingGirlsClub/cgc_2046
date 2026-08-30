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

class CoursePanelViewTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))

  def test_panel_registers_workspace
    assert_includes VIEW, 'Clacky.ext.ui.registerWorkspace'
    assert_includes VIEW, '"cgc-2046-course"'
  end

  def test_learning_center_layout
    assert_includes VIEW, "cglc-page"
    assert_includes VIEW, "cglc-side"
    assert_includes VIEW, "cglc-tree"
    assert_includes VIEW, 'data-testid="panel-course-select"'
    assert_includes VIEW, 'data-testid="panel-outline-tree"'
  end

  def test_outline_tree_marks_mastery_and_locks
    assert_includes VIEW, 'data-testid="panel-outline-node"'
    assert_includes VIEW, "cglc-g-mastered"
    assert_includes VIEW, "cglc-g-developing"
    assert_includes VIEW, "cglc-g-todo"
    assert_includes VIEW, "is-locked"
    assert_includes VIEW, 'data-testid="panel-outline-review"'
    assert_includes VIEW, "issueTitle"
  end

  def test_overview_state_resume_and_progress
    assert_includes VIEW, 'data-testid="panel-progress"'
    assert_includes VIEW, 'data-testid="panel-resume"'
    assert_includes VIEW, 'data-testid="panel-resume-btn"'
    assert_includes VIEW, "继续学习"
    assert_includes VIEW, 'data-testid="panel-stale"'
  end

  def test_objective_detail_state
    assert_includes VIEW, 'data-testid="panel-obj-badge"'
    assert_includes VIEW, "学习活动"
    assert_includes VIEW, "评价标准 (rubric)"
    assert_includes VIEW, "co.materials"
    assert_includes VIEW, "co.rubric"
    assert_includes VIEW, 'data-testid="panel-obj-learn"'
    assert_includes VIEW, "ctaDisabled"
  end

  def test_learning_actions_via_session_injection
    # 面板视图内无会话输入框——先创建并进入会话再注入(真机实证)
    assert_includes VIEW, "goLearnObjective"
    assert_includes VIEW, 'fetch("/api/sessions"'
    assert_includes VIEW, "Clacky.Sessions.select(session.id)"
    assert_includes VIEW, "injectIntoComposer"
    assert_includes VIEW, "input.textContent = text"
    assert_includes VIEW, "七步学习循环"
    assert_includes VIEW, "这是一次到期复习"
    assert_includes VIEW, "submit_learning_attempt"
    refute_includes VIEW, 'data-testid="panel-cta"'
    refute_includes VIEW, 'data-testid="panel-next-action"'
    refute_includes VIEW, 'apiPost("/learning/start"'
  end

  def test_teaching_editor_split_out
    assert_includes VIEW, "教研工作台"
    assert_includes VIEW, '"cgc-2046-curriculum"'
    refute_includes VIEW, "panel-edit-toggle"
    refute_includes VIEW, "collectEditor"
    refute_includes VIEW, "get_prep_status"
  end

  def test_panel_uses_learning_state_source
    assert_includes VIEW, '"/learning_state?workspace_id="'
    assert_includes VIEW, '"/content"'
    assert_includes VIEW, '"/revision"'
    assert_includes VIEW, "Promise.all"
    refute_includes VIEW, '"/records"'
  end

  def test_not_connected_guidance_view
    assert_includes VIEW, 'data-testid="panel-not-connected"'
    assert_includes VIEW, "503"
  end

  def test_course_scope_follows_enrollment_workspace
    # 跨台报名:课程作用域 = 报名所在 workspace(与 hub 选择器解耦;S7 语义找回)。
    # 三源请求、轮询、注入指令全部按课程归属台;下拉按 workspace 分组展示
    assert_includes VIEW, "function scopeOf(courseId)"
    assert_includes VIEW, "course.workspaceId) || state.workspaceId"
    assert_includes VIEW, "scopeOf(state.selectedCourseId)"
    assert_includes VIEW, "workspace_id: \" + wsId + \""
    assert_includes VIEW, "optgroup"
  end

  def test_focus_refresh_reloads_workspaces
    # 焦点回归(visibilitychange)重拉角色快照:后台授角色后回前台自动生效;
    # 视图态在 state,重渲染不丢
    assert_includes VIEW, 'document.addEventListener("visibilitychange"'
    assert_includes VIEW, "reloadWorkspaces"
    assert_includes VIEW, "if (next.length > 0) state.workspaces = next"
  end

  def test_polling_signature_and_lifecycle
    assert_includes VIEW, "setInterval"
    assert_includes VIEW, "clearInterval"
    assert_includes VIEW, "POLL_MS = 10000"
    assert_includes VIEW, "learningSignature"
    assert_includes VIEW, "document.hidden"
  end
end
