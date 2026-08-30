# frozen_string_literal: true

# S7-extension Learner 发现/报名/支付 loopback 路由测试(R30–R35/AE3/AE6–AE8):
# - 五端点注册与透传 JSON 形状(MCP registry call_tool 透传;工具合同
#   discover_offerings / get_enrollment_summary / create_enrollment /
#   get_my_enrollments / get_order_status 由并行 backend 切片交付,
#   本仓按合同钉参数与错误分层)
# - 必填校验:GET /enrollment_summary 三参数缺一 → 400;POST /enrollments
#   workspace_id/kind/offering_id 必填 + kind 枚举(event|course)→ 400;
#   GET /order_status 两参数缺一 → 400(均不下发 registry)
# - POST 可选参数 reason/tier_id 空值不下发,非空原样透传
# - 未连接态(registry 未配置 cgc-2046)→ 503 + 引导信息;上游错误分层:
#   McpError → 502,意外异常 → 500("learner route failed" 前缀)
# - 发现面板 v2 静态断言(/discover 数据源/报名确认卡/幂等提交/支付轮询/
#   状态徽章/仅邀请降级)+ 课程面板 /me/enrollments 列表源静态断言
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/learner_journey_routes_test.rb

require "minitest/autorun"
require "json"
require "open3"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/mcp/client")

require_relative "../api/handler"

class LearnerJourneyRoutesTest < Minitest::Test
  WS  = "ws-uuid-1"
  ENR = "enr-uuid-1"
  OFF = "off-uuid-1"

  DISCOVER_PAYLOAD = {
    "offerings" => [
      { "kind" => "course", "id" => OFF, "title" => "Web 入门", "slug" => "web-101",
        "workspace" => { "id" => WS, "name" => "Ruby 社", "slug" => "ruby" },
        "visibility" => "public", "status" => "open",
        "pricing" => { "enabled" => false, "min_amount_cents" => nil },
        "registration_deadline" => nil, "my_enrollment" => nil }
    ],
    "total_count" => 1
  }.freeze

  SUMMARY_PAYLOAD = {
    "offering" => { "id" => OFF, "title" => "Web 入门", "registration_deadline" => nil },
    "policy" => "open",
    "pricing" => { "enabled" => false, "tiers" => [] },
    "would_create_status" => "confirmed",
    "my_enrollment" => nil
  }.freeze

  CREATE_PAYLOAD = {
    "enrollment" => { "id" => ENR, "status" => "confirmed", "kind" => "course",
                      "offering_id" => OFF, "workspace_id" => WS },
    "checkout_url" => nil,
    "idempotent_replay" => false
  }.freeze

  MY_ENROLLMENTS_PAYLOAD = {
    "enrollments" => [
      { "id" => ENR, "kind" => "course",
        "offering" => { "id" => OFF, "title" => "Web 入门", "slug" => "web-101" },
        "workspace" => { "id" => WS, "name" => "Ruby 社", "slug" => "ruby" },
        "status" => "confirmed", "tier_snapshot" => nil,
        "inserted_at" => "2026-09-01T00:00:00Z" }
    ]
  }.freeze

  LEARNING_STATE_PAYLOAD = {
    "run" => { "id" => "run-1", "status" => "running", "revision_id" => "rev-1", "revision_number" => 1 },
    "revision_number" => 1,
    "stale_revision" => false,
    "objectives" => [
      { "id" => "obj-1", "title" => "能运行程序", "required" => true, "issue_id" => "issue-1",
        "prereq_ids" => [], "mastery" => "developing", "ever_mastered" => false, "locked" => false,
        "missing_prereq_ids" => [], "attempt_count" => 1, "last_attempt_at" => nil }
    ],
    "next_action" => { "kind" => "developing", "objective_id" => "obj-1", "reason" => "继续攻克「能运行程序」" },
    "progress" => { "mastered_required" => 0, "total_required" => 1, "complete" => false }
  }.freeze

  REVISION_PAYLOAD = {
    "course_id" => OFF, "revision_number" => 1, "published_at" => "2026-09-01T00:00:00Z",
    "goals" => ["目标"], "issues" => []
  }.freeze

  ORDER_STATUS_PAYLOAD = {
    "order" => { "id" => "ord-1", "amount_cents" => 9900, "provider" => "wechat",
                 "status" => "pending", "expires_at" => "2026-09-01T00:15:00Z", "paid_at" => nil },
    "checkout_url" => "https://codingirlsclub.com/orders/new?enrollmentId=#{ENR}",
    "enrollment_status" => "payment_pending"
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

      @result || { "content" => [{ "type" => "text", "text" => JSON.generate({}) }] }
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

  # advisor F2:req 加 headers(Rack 风格小写键,同宿主 WEBrick #header)
  FakeReq = Struct.new(:body, :query, :header) do
    def headers
      header || {}
    end
  end

  # 宿主真实形态(course_routes_test 同款,smoke01 实证):
  #   @params = route pattern captures(symbol key)
  #   POST body 在 req.body(JSON 字符串);GET query 在 req.query,不进 @params
  def build(registry:, body: nil, query: {}, params: {}, header: {})
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(body && JSON.generate(body), query, header))
    inst.instance_variable_set(:@params, params)
    inst.instance_variable_set(:@http_server, registry && FakeServer.new(registry))
    inst
  end

  def invoke(method, pattern, inst)
    route = Cgc2046Ext.routes.find { |r| r.method == method && r.pattern == pattern }
    refute_nil route, "route #{method} #{pattern} 未注册"
    assert_raises(Clacky::ApiExtension::Halt) { inst.instance_exec(&route.block) }
  end

  # POST /enrollments 的面板同款写头（advisor F2：json Content-Type + CSRF token）
  def write_headers
    { "Content-Type" => "application/json", "X-CGC-CSRF-Token" => Cgc2046Ext.csrf_token }
  end

  def enroll(registry:, body:)
    invoke(:post, "/enrollments", build(registry: registry, body: body, header: write_headers))
  end

  # ---- 路由注册 ----

  def test_learner_routes_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }
    assert_includes routes, [:get, "/discover"]
    assert_includes routes, [:get, "/enrollment_summary"]
    assert_includes routes, [:post, "/enrollments"]
    assert_includes routes, [:get, "/me/enrollments"]
    assert_includes routes, [:get, "/order_status"]
  end

  # ---- GET /discover → discover_offerings(无参数透传,跨 workspace 合并面孔) ----

  def test_discover_transfers_discover_offerings
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(DISCOVER_PAYLOAD) }] })

    halt = invoke(:get, "/discover", build(registry: registry))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "discover_offerings", body["tool"]
    assert_equal DISCOVER_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "discover_offerings", {}]], registry.calls
  end

  def test_discover_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/discover", build(registry: registry))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_discover_no_http_server_503
    halt = invoke(:get, "/discover", build(registry: nil))

    assert_equal 503, halt.status
  end

  def test_discover_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/discover", build(registry: registry))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_discover_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/discover", build(registry: registry))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "learner route failed"
  end

  # ---- GET /enrollment_summary → get_enrollment_summary(三参数必填) ----

  def test_summary_transfers_all_params
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(SUMMARY_PAYLOAD) }] })
    query = { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF }

    halt = invoke(:get, "/enrollment_summary", build(registry: registry, query: query))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_enrollment_summary", body["tool"]
    assert_equal SUMMARY_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_enrollment_summary", query]], registry.calls
  end

  def test_summary_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "kind" => "course", "offering_id" => OFF }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_summary_missing_kind_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "workspace_id" => WS, "offering_id" => OFF }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "kind"
    assert_empty registry.calls
  end

  def test_summary_missing_offering_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "workspace_id" => WS, "kind" => "course" }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "offering_id"
    assert_empty registry.calls
  end

  def test_summary_not_connected_503
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF }))

    assert_equal 503, halt.status
    assert_empty registry.calls
  end

  def test_summary_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("forbidden: invite only"))

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF }))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "invite only"
  end

  def test_summary_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/enrollment_summary",
                  build(registry: registry, query: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF }))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "learner route failed"
  end

  # ---- POST /enrollments → create_enrollment(幂等;body 校验) ----

  def test_create_transfers_required_body
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(CREATE_PAYLOAD) }] })

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF })

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "create_enrollment", body["tool"]
    assert_equal CREATE_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "create_enrollment",
                   { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF }]],
                 registry.calls
  end

  # reason/tier_id 可选:非空原样透传
  def test_create_passes_optional_reason_and_tier_id
    registry = FakeRegistry.new

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "event", "offering_id" => OFF,
                          "reason" => "想学", "tier_id" => "tier-1" })

    assert_equal 200, halt.status
    assert_equal({ "workspace_id" => WS, "kind" => "event", "offering_id" => OFF,
                   "reason" => "想学", "tier_id" => "tier-1" },
                 registry.calls[0][2])
  end

  # 可选参数空串不下发
  def test_create_omits_blank_optional_params
    registry = FakeRegistry.new

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF,
                          "reason" => "  ", "tier_id" => "" })

    assert_equal 200, halt.status
    assert_equal({ "workspace_id" => WS, "kind" => "course", "offering_id" => OFF },
                 registry.calls[0][2])
  end

  # 幂等重放(AE3):上游返回 idempotent_replay: true 原样透传,永不报错
  def test_create_idempotent_replay_flows_through
    replay = CREATE_PAYLOAD.merge("idempotent_replay" => true)
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(replay) }] })

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF })

    assert_equal 200, halt.status
    assert_equal true, JSON.parse(halt.payload)["result"]["idempotent_replay"]
  end

  def test_create_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = enroll(registry: registry, body: { "kind" => "course", "offering_id" => OFF })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_create_missing_kind_400
    registry = FakeRegistry.new

    halt = enroll(registry: registry, body: { "workspace_id" => WS, "offering_id" => OFF })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "kind"
    assert_empty registry.calls
  end

  def test_create_invalid_kind_400
    registry = FakeRegistry.new

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "party", "offering_id" => OFF })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "kind"
    assert_empty registry.calls
  end

  def test_create_missing_offering_id_400
    registry = FakeRegistry.new

    halt = enroll(registry: registry, body: { "workspace_id" => WS, "kind" => "course" })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "offering_id"
    assert_empty registry.calls
  end

  def test_create_empty_body_400
    registry = FakeRegistry.new

    halt = enroll(registry: registry, body: nil)

    assert_equal 400, halt.status
    assert_empty registry.calls
  end

  def test_create_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF })

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_create_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF })

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_create_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = enroll(registry: registry,
                  body: { "workspace_id" => WS, "kind" => "course", "offering_id" => OFF })

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "learner route failed"
  end

  # ---- GET /me/enrollments → get_my_enrollments(无参数透传) ----

  def test_my_enrollments_transfers_get_my_enrollments
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(MY_ENROLLMENTS_PAYLOAD) }] })

    halt = invoke(:get, "/me/enrollments", build(registry: registry))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "get_my_enrollments", body["tool"]
    assert_equal MY_ENROLLMENTS_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_my_enrollments", {}]], registry.calls
  end

  def test_my_enrollments_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/me/enrollments", build(registry: registry))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_my_enrollments_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/me/enrollments", build(registry: registry))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_my_enrollments_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/me/enrollments", build(registry: registry))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "learner route failed"
  end

  # ---- S8 学习路由 ----

  def test_learning_state_transfers_both_params
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(LEARNING_STATE_PAYLOAD) }] })
    query = { "workspace_id" => WS, "course_id" => OFF }

    halt = invoke(:get, "/learning_state", build(registry: registry, query: query))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_learning_state", body["tool"]
    assert_equal LEARNING_STATE_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_learning_state", query]], registry.calls
  end

  def test_learning_state_missing_params_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/learning_state", build(registry: registry, query: { "course_id" => OFF }))
    assert_equal 400, halt.status
    assert_empty registry.calls

    halt2 = invoke(:get, "/learning_state", build(registry: registry, query: { "workspace_id" => WS }))
    assert_equal 400, halt2.status
    assert_empty registry.calls
  end

  def test_learning_start_posts_and_requires_csrf
    registry = FakeRegistry.new

    # 缺 token → 403,零 call（guard_write!）
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(JSON.generate({ "workspace_id" => WS, "course_id" => OFF }), {},
                                                  { "Content-Type" => "application/json" })
    )
    inst.instance_variable_set(:@params, {})
    inst.instance_variable_set(:@http_server, FakeServer.new(registry))
    halt = invoke(:post, "/learning/start", inst)
    assert_equal 403, halt.status
    assert_empty registry.calls

    # 带写头 → 透传
    halt2 = invoke(:post, "/learning/start", build(registry: registry,
                                                   body: { "workspace_id" => WS, "course_id" => OFF },
                                                   header: write_headers))
    assert_equal 200, halt2.status
    assert_equal [["cgc-2046", "start_learning_run", { "workspace_id" => WS, "course_id" => OFF }]], registry.calls
  end

  # 实证合同(UAT 真机 -32602):上游 get_course_revision 必填 workspace_id,
  # 路由层缺参 400(不下发 registry),带参原样透传
  def test_revision_route_transfers_course_and_workspace
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(REVISION_PAYLOAD) }] })

    halt = invoke(:get, "/courses/:course_id/revision",
                  build(registry: registry, params: { course_id: OFF }, query: { "workspace_id" => WS }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_course_revision", body["tool"]
    assert_equal REVISION_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_course_revision", { "course_id" => OFF, "workspace_id" => WS }]],
                 registry.calls
  end

  def test_revision_route_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/courses/:course_id/revision", build(registry: registry, params: { course_id: OFF }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls, "缺参不得下发 registry"
  end

  def test_retired_record_routes_not_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }
    refute_includes routes, [:get, "/courses"]
    refute_includes routes, [:get, "/courses/:course_id/records"]
  end

  # ---- GET /order_status → get_order_status(两参数必填) ----

  def test_order_status_transfers_both_params
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(ORDER_STATUS_PAYLOAD) }] })
    query = { "workspace_id" => WS, "enrollment_id" => ENR }

    halt = invoke(:get, "/order_status", build(registry: registry, query: query))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_order_status", body["tool"]
    assert_equal ORDER_STATUS_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_order_status", query]], registry.calls
  end

  def test_order_status_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/order_status", build(registry: registry, query: { "enrollment_id" => ENR }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_order_status_missing_enrollment_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/order_status", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "enrollment_id"
    assert_empty registry.calls
  end

  def test_order_status_not_connected_503
    halt = invoke(:get, "/order_status",
                  build(registry: nil, query: { "workspace_id" => WS, "enrollment_id" => ENR }))

    assert_equal 503, halt.status
  end

  def test_order_status_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/order_status",
                  build(registry: registry, query: { "workspace_id" => WS, "enrollment_id" => ENR }))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_order_status_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/order_status",
                  build(registry: registry, query: { "workspace_id" => WS, "enrollment_id" => ENR }))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "learner route failed"
  end
end

# ---- advisor R2 advisory-3:面板 403-on-CSRF 自愈(重取 token 重试一次) ----

class PanelCsrfSelfHealTest < Minitest::Test
  DISCOVERY_VIEW = File.read(File.expand_path("../panels/cgc-discovery/view.js", __dir__))
  COURSE_VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))
  WORKSPACE_VIEW = File.read(File.expand_path("../panels/workspace/view.js", __dir__))
  HARNESS = File.expand_path("panel_behavior_harness.js", __dir__)
  COURSE_VIEW_PATH = File.expand_path("../panels/cgc-course/view.js", __dir__)

  def test_discovery_api_post_retries_once_on_csrf_403
    assert_includes DISCOVERY_VIEW, "async function refreshCsrf()"
    assert_includes DISCOVERY_VIEW, 'res.status === 403 && (await refreshCsrf())'
    # 重试只一次(无循环):403 分支后无再次重试的嵌套
    refute_includes DISCOVERY_VIEW, "refreshCsrf())) && (await refreshCsrf()"
  end

  def test_course_api_post_retries_once_on_csrf_403
    assert_includes COURSE_VIEW, "async function refreshCsrf()"
    assert_includes COURSE_VIEW, 'res.status === 403 && (await refreshCsrf())'
    refute_includes COURSE_VIEW, "refreshCsrf())) && (await refreshCsrf()"
  end
  # workspace 面板 disconnect（DELETE）与 POST 写路由同规：带 token + 403 自愈一次
  def test_workspace_api_delete_retries_once_on_csrf_403
    assert_includes WORKSPACE_VIEW, "async function refreshCsrf()"
    assert_includes WORKSPACE_VIEW, 'res.status === 403 && (await refreshCsrf())'
    refute_includes WORKSPACE_VIEW, "refreshCsrf())) && (await refreshCsrf()"
  end

  # advisor R3:harness 的 csrf_retry_self_heal 场景已删除——该场景在
  # spec.render 前 process.exit(0),fetch 序列由 harness 自身 stub 完成,
  # view.js 的 apiPost 未参与(自导自演的假验证,不留)。自愈的验证面:
  #   1) 上方两测试的代码路径静态锚(自愈在场 + 仅一次 + 无嵌套);
  #   2) 路由层 CsrfGuardTest 的 token 匹配/403 语义;
  #   3) 真实 DOM 级驱动需要面板暴露内部函数或完整编辑器流,污染生产代码
  #      不值得——留真机 e2e(人类验收面)。
end

# ---- advisor F1:课程面板 boot 解耦的行为级断言(Node harness 执行 view.js) ----

class CoursePanelBehaviorTest < Minitest::Test
  HARNESS = File.expand_path("panel_behavior_harness.js", __dir__)
  VIEW = File.expand_path("../panels/cgc-course/view.js", __dir__)

  def test_zero_member_confirmed_enrollment_lists_course
    # AE8/R35 行为证据(非字符串扫描):零成员身份(/me/workspaces 返回空)下
    # /me/enrollments 仍无条件拉取,confirmed 公开课报名出现在可学习列表,
    # 行携带报名 workspace 作用域(data-ws),pending 报名入「报名进行中」区,
    # 无 workspace gate 阻断。
    out, status = Open3.capture2e("node", HARNESS, VIEW, "zero_member_confirmed")
    assert status.success?, "harness 失败: #{out}"
    assert_includes out, "OK zero_member_confirmed"
    assert_includes out, '"enrollments_fetched_without_membership":true'
    assert_includes out, '"confirmed_course_visible":true'
    assert_includes out, '"row_carries_enrollment_workspace_scope":true'
    assert_includes out, '"in_flight_section_rendered":true'
    assert_includes out, '"no_workspace_gate_blocking_list":true'
  end
end

# ---- advisor F2:loopback 请求来源收口(Origin 同源 / 写路由 Content-Type + CSRF) ----

class CsrfGuardTest < Minitest::Test
  LOCAL = { "Host" => "127.0.0.1:4114" }.freeze
  EVIL  = { "Host" => "127.0.0.1:4114", "Origin" => "https://evil.example" }.freeze

  def fake_registry
    @fake_registry ||= begin
      reg = LearnerJourneyRoutesTest::FakeRegistry.new
      reg
    end
  end

  def build_inst(header:, body: nil)
    inst = Cgc2046Ext.allocate
    req = LearnerJourneyRoutesTest::FakeReq.new(body && JSON.generate(body), {}, header)
    inst.instance_variable_set(:@req, req)
    inst.instance_variable_set(:@params, {})
    inst
  end

  def invoke(method, pattern, inst)
    route = Cgc2046Ext.routes.find { |r| r.method == method && r.pattern == pattern }
    refute_nil route
    assert_raises(Clacky::ApiExtension::Halt) { inst.instance_exec(&route.block) }
  end

  def with_fake_server(header:, body: nil)
    inst = Cgc2046Ext.allocate
    req = LearnerJourneyRoutesTest::FakeReq.new(body && JSON.generate(body), {}, header)
    inst.instance_variable_set(:@req, req)
    inst.instance_variable_set(:@params, {})
    reg = LearnerJourneyRoutesTest::FakeRegistry.new
    inst.instance_variable_set(:@http_server, LearnerJourneyRoutesTest::FakeServer.new(reg))
    [inst, reg]
  end

  def test_cross_origin_get_403_zero_registry_calls
    inst, reg = with_fake_server(header: EVIL)
    halt = invoke(:get, "/discover", inst)
    assert_equal 403, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "cross-origin"
    assert_empty reg.calls
  end
  # learning_state / revision 曾漏挂 guard_origin!（相对「全部路由收口」声明的
  # 回归钉子）：跨源 → 403，零 registry 调用
  def test_cross_origin_learning_state_403_zero_registry_calls
    inst, reg = with_fake_server(header: EVIL)
    halt = invoke(:get, "/learning_state", inst)
    assert_equal 403, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "cross-origin"
    assert_empty reg.calls
  end

  def test_cross_origin_course_revision_403_zero_registry_calls
    inst, reg = with_fake_server(header: EVIL)
    halt = invoke(:get, "/courses/:course_id/revision", inst)
    assert_equal 403, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "cross-origin"
    assert_empty reg.calls
  end

  def test_cross_origin_plain_text_post_403_zero_calls
    inst, reg = with_fake_server(header: EVIL.merge("Content-Type" => "text/plain"),
                                 body: { "workspace_id" => "ws", "kind" => "course", "offering_id" => "o" })
    halt = invoke(:post, "/enrollments", inst)
    assert_equal 403, halt.status
    assert_empty reg.calls
  end

  def test_same_origin_and_no_origin_allowed
    reg = LearnerJourneyRoutesTest::FakeRegistry.new

    # 无 Origin(本地 curl / 宿主内部)放行
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, LearnerJourneyRoutesTest::FakeReq.new(nil, {}, LOCAL))
    inst.instance_variable_set(:@params, {})
    inst.instance_variable_set(:@http_server, LearnerJourneyRoutesTest::FakeServer.new(reg))
    halt = invoke(:get, "/discover", inst)
    assert_equal 200, halt.status
    assert_equal 1, reg.calls.length

    # 同源 Origin 放行
    inst2 = Cgc2046Ext.allocate
    inst2.instance_variable_set(:@req, LearnerJourneyRoutesTest::FakeReq.new(nil, {}, LOCAL.merge("Origin" => "http://127.0.0.1:4114")))
    inst2.instance_variable_set(:@params, {})
    inst2.instance_variable_set(:@http_server, LearnerJourneyRoutesTest::FakeServer.new(reg))
    halt2 = invoke(:get, "/me/enrollments", inst2)
    assert_equal 200, halt2.status
    assert_equal 2, reg.calls.length
  end

  def test_write_route_requires_json_content_type_and_csrf_token
    body = { "workspace_id" => "ws", "kind" => "course", "offering_id" => "o" }

    # 同源但 text/plain(simple request 形态)→ 415,零 call
    inst, reg = with_fake_server(header: LOCAL.merge("Origin" => "http://127.0.0.1:4114", "Content-Type" => "text/plain"),
                                 body: body)
    halt = invoke(:post, "/enrollments", inst)
    assert_equal 415, halt.status
    assert_empty reg.calls

    # application/json 但无 token → 403,零 call
    inst2, reg2 = with_fake_server(header: LOCAL.merge("Content-Type" => "application/json"),
                                   body: body)
    halt2 = invoke(:post, "/enrollments", inst2)
    assert_equal 403, halt2.status
    assert_includes JSON.parse(halt2.payload)["error"], "CSRF"
    assert_empty reg2.calls

    # application/json + 正确 token → 透传 registry
    inst3, reg3 = with_fake_server(
      header: LOCAL.merge("Content-Type" => "application/json",
                          "X-CGC-CSRF-Token" => Cgc2046Ext.csrf_token),
      body: body
    )
    halt3 = invoke(:post, "/enrollments", inst3)
    assert_equal 200, halt3.status
    assert_equal [["cgc-2046", "create_enrollment", body]], reg3.calls
  end

  def test_status_delivers_csrf_token_to_same_origin
    inst, = with_fake_server(header: LOCAL)
    halt = invoke(:get, "/status", inst)
    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal Cgc2046Ext.csrf_token, body["csrf_token"]
  end
end

# ---- 发现面板 v2 view.js 结构静态断言(S7 的可测面;DOM 级 留手动冒烟) ----

class DiscoveryPanelV2Test < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-discovery/view.js", __dir__))

  def test_data_source_is_discover_not_offerings
    # S7:列表源切换到 /discover(合并面孔);旧 /offerings 读取整体移除
    assert_includes VIEW, 'apiGet("/discover")'
    refute_includes VIEW, 'apiGet("/offerings")'
    assert_includes VIEW, "result.offerings"
  end

  def test_five_state_machine_kept
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

  def test_workspace_name_label_per_row
    assert_includes VIEW, 'data-testid="panel-offering-ws"'
    assert_includes VIEW, "escapeHtml(ws.name"
  end

  def test_enroll_button_and_summary_fetch
    # status=open 且无 my_enrollment → 报名按钮 → /enrollment_summary 三参数
    assert_includes VIEW, 'item.status === "open"'
    assert_includes VIEW, 'data-testid="panel-enroll"'
    assert_includes VIEW, "报名"
    assert_includes VIEW, '"/enrollment_summary?workspace_id="'
    assert_includes VIEW, '"&kind="'
    assert_includes VIEW, '"&offering_id="'
  end

  def test_confirm_card_in_panel_not_window_confirm
    # 面板内确认卡(非 window.confirm):标题/价格档或免费/策略/deadline/将创建状态
    refute_includes VIEW, "window.confirm"
    assert_includes VIEW, 'data-testid="panel-enroll-confirm"'
    assert_includes VIEW, 'data-testid="panel-enroll-submit"'
    assert_includes VIEW, 'data-testid="panel-enroll-cancel"'
    assert_includes VIEW, "确认报名"
    assert_includes VIEW, "取消"
    assert_includes VIEW, "免费"
    # would_create_status 三态中文
    assert_includes VIEW, "直接确认"
    assert_includes VIEW, "需审批"
    assert_includes VIEW, "需支付"
  end

  def test_invite_only_degrades_to_badge
    assert_includes VIEW, 's.policy === "invite_only"'
    assert_includes VIEW, 'data-testid="panel-invite-only"'
    assert_includes VIEW, "仅邀请"
  end

  def test_submit_posts_enrollments
    assert_includes VIEW, 'apiPost("/enrollments"'
    assert_includes VIEW, 'method: "POST"'
    assert_includes VIEW, "offering_id: item.id"
    assert_includes VIEW, "body.tier_id"
  end

  def test_payment_pending_flow_and_order_poll
    # payment_pending → 去支付 + 支付中徽章 + 5s 轮询 /order_status;
    # 终态/面板离开/10 分钟上限即停;paid → 已报名(AE7);expired → 已过期
    assert_includes VIEW, 'result.checkout_url'
    assert_includes VIEW, "支付中"
    assert_includes VIEW, "去支付"
    assert_includes VIEW, '"/order_status?workspace_id="'
    assert_includes VIEW, '"&enrollment_id="'
    assert_includes VIEW, "5000"
    assert_includes VIEW, "setInterval"
    assert_includes VIEW, "clearInterval"
    assert_includes VIEW, "10 * 60 * 1000"
    assert_includes VIEW, "document.contains(currentContainer)"
    assert_includes VIEW, 'order.status === "paid"'
    assert_includes VIEW, 'result.enrollment_status === "confirmed"'
    assert_includes VIEW, 'order.status === "expired"'
    assert_includes VIEW, 'markEnrollment(id, "confirmed")'
    assert_includes VIEW, 'markEnrollment(id, "expired")'
  end

  def test_my_enrollment_status_badges
    # 既有 my_enrollment 渲染状态徽章,不再出现报名按钮
    assert_includes VIEW, "item.my_enrollment"
    assert_includes VIEW, 'data-testid="panel-enroll-badge"'
    assert_includes VIEW, "待审批"
    assert_includes VIEW, "待支付"
    assert_includes VIEW, "已报名"
    assert_includes VIEW, "已拒绝"
    assert_includes VIEW, "已过期"
    assert_includes VIEW, "已取消"
    # 既有待支付报名的去支付恢复入口
    assert_includes VIEW, 'data-testid="panel-pay-resume"'
    assert_includes VIEW, "data-resume-pay"
  end

  def test_checkout_opened_externally_and_url_validated
    # 既有外链机制(anchor target=_blank);checkout_url 非 http(s) 不渲染链接
    assert_includes VIEW, 'data-testid="panel-pay-link"'
    assert_includes VIEW, 'target="_blank"'
    assert_includes VIEW, 'rel="noopener noreferrer"'
    assert_includes VIEW, '/^https?:\/\//'
    assert_includes VIEW, 'window.open(result.checkout_url, "_blank", "noopener")'
  end

  def test_detail_link_and_refresh_kept
    # KTD9 详情链接与手动刷新保持
    assert_includes VIEW, "web_url"
    assert_includes VIEW, "/events/"
    assert_includes VIEW, "/courses/"
    assert_includes VIEW, "encodeURIComponent(item.slug)"
    assert_includes VIEW, 'id="cgc-refresh"'
    assert_includes VIEW, "刷新"
  end

  def test_dynamic_values_escaped
    assert_includes VIEW, "function escapeHtml("
    assert_includes VIEW, "escapeHtml(item.title)"
    assert_includes VIEW, "escapeHtml(item.kind)"
    assert_includes VIEW, "escapeHtml(t.name"
  end
end

# ---- 课程面板 /me/enrollments 列表源静态断言(AE8/R35) ----

class CoursePanelEnrollmentListTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))

  def test_list_source_switched_to_my_enrollments
    # 列表 = /me/enrollments(跨 workspace,裸 GET 不带 workspace_id);
    # 旧 records 反推列表路径整体移除
    assert_includes VIEW, 'rawGet("/me/enrollments")'
    refute_includes VIEW, 'apiGet("/courses")'
    refute_includes VIEW, "coursesSignature"
    refute_includes VIEW, "按学习记录推导"
  end

  def test_confirmed_filter_is_learnable_list
    # confirmed 课程报名 = 可学习课程;零学习记录也显示(条目不再依赖 records)
    assert_includes VIEW, 'e.kind === "course"'
    assert_includes VIEW, 'e.status === "confirmed"'
    refute_includes VIEW, "records.length"
    assert_includes VIEW, 'data-testid="panel-course"'
    assert_includes VIEW, "offering.title"
  end

  def test_in_flight_section_and_workspace_grouping
    # pending/payment_pending → 报名进行中区(状态徽章,无学习入口);
    # confirmed 按 workspace 分组(跨 workspace 报名)
    assert_includes VIEW, 'e.status === "pending" || e.status === "payment_pending"'
    assert_includes VIEW, "报名进行中"
    assert_includes VIEW, 'data-testid="panel-inflight"'
    assert_includes VIEW, "待审批"
    assert_includes VIEW, "待支付"
    assert_includes VIEW, 'data-testid="panel-course-group"'
    assert_includes VIEW, "workspaceName"
  end

  def test_open_course_switches_workspace_context
    # 报名跨 workspace:行携带 data-ws,打开时详情读面切到该 workspace
    assert_includes VIEW, 'data-ws='
    assert_includes VIEW, "openCourse(courseId, workspaceId)"
    assert_includes VIEW, 'el.getAttribute("data-ws")'
  end

  def test_detail_reads_objective_grain
    # S8:详情切 /learning_state(objective 口径)+ /revision 展示增强;
    # records 读面整体移除
    assert_includes VIEW, '"/learning_state?workspace_id="'
    assert_includes VIEW, '"/revision"'
        assert_includes VIEW, 'data-testid="panel-obj-row"'
    assert_includes VIEW, 'data-testid="panel-obj-locked"'
    assert_includes VIEW, 'data-testid="panel-next-action"'
    assert_includes VIEW, 'data-testid="panel-progress"'
    assert_includes VIEW, 'data-testid="panel-stale"'
    assert_includes VIEW, 'data-testid="panel-cta"'
    assert_includes VIEW, "learningSignature"
    assert_includes VIEW, "apiPost(\"/learning/start\""
    refute_includes VIEW, '"/records"'
  end
end
