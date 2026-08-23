# frozen_string_literal: true

# U6 发现面板 loopback 路由 + 面板/prompt 静态断言(plan U6 / R11-R13 + AE5;KTD4/KTD7/KTD9):
# - 两路由注册与透传(JSON 形状 + 可选过滤参数透传;公开浏览工具无 workspace_id 硬要求)
# - 未连接态(registry 未配置 cgc-2046)→ 503 + 引导信息(AE5 数据面)
# - 上游错误分层:McpError → 502,意外异常 → 500
# - 发现面板 view.js 结构静态断言(IIFE 守卫/五态状态机/badge 三态/详情链接/未连接引导)
# - system_prompt 工具清单 = 17(server.ex 实际注册数)+ 公开工具豁免 + no-fabrication 段(KTD7)
# - onboarding SKILL 提示词引导文案(R13)
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/offering_routes_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/mcp/client")

require_relative "../api/handler"

class OfferingRoutesTest < Minitest::Test
  EVENT_ID = "evt-uuid-1"

  LIST_PAYLOAD = {
    "items" => [
      { "id" => "e1", "slug" => "ruby-night", "title" => "Ruby 之夜", "kind" => "event",
        "badge" => "enrolling", "starts_at" => "2026-09-01T11:00:00Z",
        "city" => "上海", "district" => "杨浦区" },
      { "id" => "c1", "slug" => "web-101", "title" => "Web 入门", "kind" => "course",
        "badge" => "starting_soon", "starts_at" => nil, "city" => nil, "district" => nil }
    ],
    "total_count" => 2,
    "undated_count" => 1
  }.freeze

  DETAIL_PAYLOAD = {
    "id" => EVENT_ID, "kind" => "event", "slug" => "ruby-night", "title" => "Ruby 之夜",
    "description" => "…", "badge" => "enrolling",
    "venue" => { "city" => "上海", "district" => "杨浦区" }
  }.freeze

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

      @result || { "content" => [{ "type" => "text", "text" => JSON.generate({ "items" => [] }) }] }
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

  # 宿主真实形态(course_routes_test 同款,smoke01 实证):
  #   @params = route pattern captures(symbol key,如 :id)
  #   GET query 在 req.query(WEBrick),不进 @params
  def build(registry:, query: {}, params: {})
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(nil, query))
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

  def test_offering_routes_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }
    assert_includes routes, [:get, "/offerings"]
    assert_includes routes, [:get, "/offerings/:id"]
  end

  # ---- 透传(KD3:面板经 loopback 透传同一 MCP 工具,单一口径) ----

  def test_list_transfers_default_call_without_workspace_id
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(LIST_PAYLOAD) }] })

    halt = invoke(:get, "/offerings", build(registry: registry))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "list_public_offerings", body["tool"]
    assert_equal LIST_PAYLOAD, body["result"]
    # 公开浏览工具无 workspace_id 硬要求(KTD9):query 全缺省 → 空参数透传
    assert_equal [["cgc-2046", "list_public_offerings", {}]], registry.calls
  end

  def test_list_passes_optional_filters
    query = { "kind" => "event", "city" => "上海",
              "starts_after" => "2026-09-01T00:00:00Z", "starts_before" => "2026-10-01T00:00:00Z" }
    registry = FakeRegistry.new

    halt = invoke(:get, "/offerings", build(registry: registry, query: query))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "list_public_offerings", query]], registry.calls
  end

  # 空串过滤参数不下发(缺省 = 服务端「近期」口径)
  def test_list_omits_blank_filters
    registry = FakeRegistry.new

    halt = invoke(:get, "/offerings", build(registry: registry, query: { "kind" => "", "city" => "" }))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "list_public_offerings", {}]], registry.calls
  end

  def test_detail_transfers_id_and_optional_kind
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(DETAIL_PAYLOAD) }] })

    halt = invoke(:get, "/offerings/:id",
                  build(registry: registry, query: { "kind" => "event" }, params: { id: EVENT_ID }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_public_offering", body["tool"]
    assert_equal DETAIL_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_public_offering", { "id" => EVENT_ID, "kind" => "event" }]],
                 registry.calls
  end

  # id 走 route capture(symbol key,宿主真实形态);kind 缺省不下发
  def test_detail_id_via_route_capture_without_kind
    registry = FakeRegistry.new

    halt = invoke(:get, "/offerings/:id", build(registry: registry, params: { id: EVENT_ID }))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "get_public_offering", { "id" => EVENT_ID }]], registry.calls
  end

  # ---- 未连接态(AE5:引导信息,面板据此渲染连接引导) ----

  def test_list_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/offerings", build(registry: registry))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_detail_no_http_server_503
    halt = invoke(:get, "/offerings/:id", build(registry: nil, params: { id: EVENT_ID }))

    assert_equal 503, halt.status
  end

  # ---- 上游错误分层 ----

  def test_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/offerings", build(registry: registry))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/offerings", build(registry: registry))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "offering route failed"
  end
end

# ---- 发现面板 view.js 结构静态断言(状态机与 AE5 的可测面;DOM 级留手动冒烟) ----

class DiscoveryPanelViewTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-discovery/view.js", __dir__))

  def test_iife_guard_and_workspace_registration
    assert_includes VIEW, "if (!window.Clacky || !Clacky.ext || Clacky.ext.pure) return;"
    assert_includes VIEW, "Clacky.ext.ui.registerWorkspace"
    assert_includes VIEW, '"cgc-2046-discovery"'
  end

  def test_state_machine_five_views
    # Loading → NotConnected / Error / Empty / List(plan U6 状态机)
    assert_includes VIEW, '"loading"'
    assert_includes VIEW, '"not-connected"'
    assert_includes VIEW, '"error"'
    assert_includes VIEW, '"empty"'
    assert_includes VIEW, '"list"'
    assert_includes VIEW, 'data-testid="panel-loading"'
    assert_includes VIEW, 'data-testid="panel-not-connected"'
    assert_includes VIEW, 'data-testid="panel-error"'
    assert_includes VIEW, 'data-testid="panel-empty"'
    assert_includes VIEW, 'data-testid="panel-offering"'
  end

  def test_not_connected_guidance_and_retry
    # AE5:未连接 → 连接引导视图(非报错非空白);重试回 Loading
    assert_includes VIEW, "503"
    assert_includes VIEW, "连接"
    assert_includes VIEW, 'data-testid="panel-retry"'
    assert_includes VIEW, "#cgc-retry"
  end

  def test_badge_three_states_chinese
    # KTD4:badge 三态 enrolling/starting_soon/full → 报名中/即将开始/已满
    assert_includes VIEW, "enrolling"
    assert_includes VIEW, "starting_soon"
    assert_includes VIEW, '"full"'
    assert_includes VIEW, "报名中"
    assert_includes VIEW, "即将开始"
    assert_includes VIEW, "已满"
  end

  def test_undated_and_location_rendering
    # KTD4:无 starts_at → 「时间待定」;KD6:event 有 city/district 才显示,course 无位置槽
    assert_includes VIEW, "时间待定"
    assert_includes VIEW, 'item.kind !== "event"'
    assert_includes VIEW, "item.city"
    assert_includes VIEW, "item.district"
  end

  def test_detail_link_to_web
    # KTD9:条目跳 web 详情(web_url 经 /status 透传 + /events|/courses/<slug>)
    assert_includes VIEW, "web_url"
    assert_includes VIEW, "/events/"
    assert_includes VIEW, "/courses/"
    assert_includes VIEW, "encodeURIComponent(item.slug)"
    assert_includes VIEW, 'target="_blank"'
    assert_includes VIEW, 'rel="noopener noreferrer"'
  end

  def test_dynamic_values_escaped
    assert_includes VIEW, "function escapeHtml("
    assert_includes VIEW, "escapeHtml(item.title)"
    assert_includes VIEW, "escapeHtml(item.badge)"
  end

  def test_panel_is_read_only_and_workspace_scoped_free
    # 纯视图零写操作;公开浏览不下发 workspace 作用域参数(KTD9)
    refute_match(/method:\s*["'](?:POST|PUT|DELETE|PATCH)["']/, VIEW)
    refute_includes VIEW, "workspace_id"
  end
end

# ---- 助手 prompt 与 onboarding 文案静态断言(KTD7/R13) ----

class AssistantPromptTest < Minitest::Test
  PROMPT = File.read(File.expand_path("../agents/cgc-assistant/system_prompt.md", __dir__))
  SKILL = File.read(File.expand_path("../skills/cgc2046-onboarding/SKILL.md", __dir__))

  # 真镜像:解析 server.ex 的 component(Cgc2046.Mcp.Tools.<Mod>) 注册行,
  # 模块名 underscore 后即注册工具清单;prompt 清单必须与之逐项一致(防两侧漂移)。
  SERVER_EX = File.read(File.expand_path("../../../backend/lib/cgc_2046/mcp/server.ex", __dir__))
  REGISTERED_TOOLS = SERVER_EX.scan(/component\(Cgc2046\.Mcp\.Tools\.(\w+)\)/).flatten
    .map { |mod| mod.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase }
    .freeze

  def test_tool_inventory_is_17_and_matches_server_registration
    assert_includes PROMPT, "工具清单（17 个）"
    listed = PROMPT.scan(/^- `([a-z_0-9]+)`/).flatten
    assert_equal 17, listed.size, "工具清单列表项应为 17,实际 #{listed.size}"
    assert_equal REGISTERED_TOOLS.sort, listed.sort
  end

  def test_public_tools_workspace_id_exemption
    # KTD7:workspace_id 毯规则的公开工具例外
    assert_includes PROMPT, "无需 `workspace_id`"
    assert_includes PROMPT, "list_public_offerings"
    assert_includes PROMPT, "get_public_offering"
  end

  def test_no_fabrication_section
    # KTD7:只答工具返回的条目、空结果直说没有、地点只取自用户话语缺则追问
    assert_includes PROMPT, "no-fabrication"
    assert_includes PROMPT, "绝不编造"
    assert_includes PROMPT, "没有匹配条目"
    assert_includes PROMPT, "追问地点"
  end

  def test_onboarding_prompt_guidance
    # R13:完成语含发现类提示词引导
    assert_includes SKILL, "最近有什么活动/课程"
    assert_includes SKILL, "CGC 发现"
  end
end
