# frozen_string_literal: true

# role-agent-journeys-v2 S1-extension 工作台数据面 loopback 路由测试:
# - 三端点注册与透传 JSON 形状(MCP registry call_tool 透传;
#   工具 list_my_workspaces / get_role_playbook / list_my_tasks 由本片 backend 交付)
# - 未连接态(registry 未配置 cgc-2046)→ 503 + 引导信息
# - 上游错误分层:McpError → 502,意外异常 → 500
# - 必填 query 缺失(/playbook 的 role、/tasks 的 workspace_id)→ 400(不下发 registry)
# - query 三层兜底回归(真实宿主 GET query 不进 @params,handler.rb route_params_value)
# - 面板 view.js 结构静态断言(workspace 身份栏/选择器/任务区)
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/workbench_routes_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/mcp/client")

require_relative "../api/handler"

class WorkbenchRoutesTest < Minitest::Test
  WS = "ws-uuid-1"

  WORKSPACES_PAYLOAD = {
    "workspaces" => [
      { "workspace_id" => WS, "name" => "Ruby 社", "slug" => "ruby", "roles" => ["owner"] }
    ],
    "is_platform_admin" => false
  }.freeze

  PLAYBOOK_PAYLOAD = { "role" => "learner", "version" => "2026-08-29.1", "content" => "# learner playbook" }.freeze

  TASKS_PAYLOAD = {
    "tasks" => [
      { "kind" => "join_request", "id" => "t1", "requester_name" => "小张",
        "context_title" => "Ruby 社", "approval_deadline" => "2026-09-01T00:00:00Z",
        "workspace_slug" => "ruby" }
    ],
    "count" => 1,
    "workspace_id" => WS
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

  FakeReq = Struct.new(:body, :query)

  # 宿主真实形态(course_routes_test 同款,smoke01 实证):
  #   @params = route pattern captures(symbol key)
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

  def test_workbench_routes_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }
    assert_includes routes, [:get, "/me/workspaces"]
    assert_includes routes, [:get, "/playbook"]
    assert_includes routes, [:get, "/tasks"]
  end

  # ---- 透传(合同形状:list_my_workspaces / get_role_playbook / list_my_tasks) ----

  def test_me_workspaces_transfers_list_my_workspaces
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(WORKSPACES_PAYLOAD) }] })

    halt = invoke(:get, "/me/workspaces", build(registry: registry))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "list_my_workspaces", body["tool"]
    assert_equal WORKSPACES_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "list_my_workspaces", {}]], registry.calls
  end

  def test_playbook_transfers_role_and_optional_workspace_id
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(PLAYBOOK_PAYLOAD) }] })

    halt = invoke(:get, "/playbook",
                  build(registry: registry, query: { "role" => "learner", "workspace_id" => WS }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "get_role_playbook", body["tool"]
    assert_equal PLAYBOOK_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "get_role_playbook", { "role" => "learner", "workspace_id" => WS }]],
                 registry.calls
  end

  # workspace_id 可选(平台管理模式 platform_admin 无 workspace 上下文),缺省不下发
  def test_playbook_without_workspace_id_omits_it
    registry = FakeRegistry.new

    halt = invoke(:get, "/playbook",
                  build(registry: registry, query: { "role" => "platform_admin" }))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "get_role_playbook", { "role" => "platform_admin" }]], registry.calls
  end

  def test_tasks_transfers_workspace_id
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(TASKS_PAYLOAD) }] })

    halt = invoke(:get, "/tasks", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "list_my_tasks", body["tool"]
    assert_equal TASKS_PAYLOAD, body["result"]
    assert_equal [["cgc-2046", "list_my_tasks", { "workspace_id" => WS }]], registry.calls
  end

  # ---- 必填 query 缺失 → 400(不下发 registry) ----

  def test_playbook_missing_role_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/playbook", build(registry: registry, query: {}, params: {}))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "role"
    assert_empty registry.calls
  end

  def test_tasks_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = invoke(:get, "/tasks", build(registry: registry, query: {}, params: {}))

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  # ---- 未连接态 → 503 + 引导信息(不下发 registry) ----

  def test_me_workspaces_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/me/workspaces", build(registry: registry))

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  def test_playbook_not_connected_503
    registry = FakeRegistry.new(configured: false)

    halt = invoke(:get, "/playbook", build(registry: registry, query: { "role" => "tutor" }))

    assert_equal 503, halt.status
    assert_empty registry.calls
  end

  def test_tasks_no_http_server_503
    halt = invoke(:get, "/tasks", build(registry: nil, query: { "workspace_id" => WS }))

    assert_equal 503, halt.status
  end

  # ---- 上游错误分层:McpError → 502,意外异常 → 500 ----

  def test_me_workspaces_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/me/workspaces", build(registry: registry))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_playbook_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("forbidden: not a member"))

    halt = invoke(:get, "/playbook", build(registry: registry, query: { "role" => "tutor", "workspace_id" => WS }))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "forbidden"
  end

  def test_tasks_mcp_error_502
    registry = FakeRegistry.new(error: Clacky::Mcp::Client::McpError.new("boom"))

    halt = invoke(:get, "/tasks", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "boom"
  end

  def test_me_workspaces_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/me/workspaces", build(registry: registry))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workbench route failed"
  end

  def test_playbook_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/playbook", build(registry: registry, query: { "role" => "tutor" }))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workbench route failed"
  end

  def test_tasks_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = invoke(:get, "/tasks", build(registry: registry, query: { "workspace_id" => WS }))

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workbench route failed"
  end

  # ---- query 三层兜底回归(smoke01 #1):真实宿主 GET query 不进 @params ----

  def test_playbook_role_via_query_when_params_empty
    registry = FakeRegistry.new

    halt = invoke(:get, "/playbook",
                  build(registry: registry, query: { "role" => "workspace_admin" }, params: {}))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "get_role_playbook", { "role" => "workspace_admin" }]], registry.calls
  end

  def test_tasks_workspace_id_via_query_when_params_empty
    registry = FakeRegistry.new

    halt = invoke(:get, "/tasks", build(registry: registry, query: { "workspace_id" => WS }, params: {}))

    assert_equal 200, halt.status
    assert_equal [["cgc-2046", "list_my_tasks", { "workspace_id" => WS }]], registry.calls
  end
end

# ---- 面板 view.js 结构静态断言(S1-extension 的可测面;DOM 级留手动冒烟) ----

class WorkspacePanelViewTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/workspace/view.js", __dir__))

  def test_workbench_sections_present
    # 身份栏 / Workspace 选择器 / 我的任务三区挂载点
    assert_includes VIEW, 'id="cgc-workbench"'
    assert_includes VIEW, 'id="cgc-identity"'
    assert_includes VIEW, 'id="cgc-ws-select"'
    assert_includes VIEW, 'id="cgc-tasks"'
    assert_includes VIEW, 'id="cgc-tasks-refresh"'
  end

  def test_workbench_data_channels
    assert_includes VIEW, '"/me/workspaces"'
    assert_includes VIEW, '"/tasks?workspace_id="'
  end

  def test_workspace_selection_persisted_under_new_key
    assert_includes VIEW, "cgc2046.workspacePanel.workspaceId"
    assert_includes VIEW, "localStorage.setItem"
    # 失效回退:持久化 id 不在列表时回退第一项
    assert_includes VIEW, "workspaces[0]"
  end

  def test_identity_badges_and_empty_states
    assert_includes VIEW, "平台管理模式"
    assert_includes VIEW, "is_platform_admin"
    assert_includes VIEW, "暂无待办"
    assert_includes VIEW, "approval_deadline"
  end

  def test_task_row_shows_requester_and_target_resource
    # 任务行摘要 = 申请人 → 目标资源(R4 身份栏三要素之目标资源落在任务行)
    assert_includes VIEW, "t.requester_name"
    assert_includes VIEW, "t.context_title"
  end

  def test_server_strings_escaped
    assert_includes VIEW, "function escapeHtml("
    assert_includes VIEW, "escapeHtml(current.name"
    assert_includes VIEW, "escapeHtml(r)"
    assert_includes VIEW, "escapeHtml(t.kind"
    assert_includes VIEW, "escapeHtml(taskSummary(t))"
  end

  def test_uuid_never_requested_from_user
    refute_includes VIEW, "UUID"
    refute_includes VIEW, "cgc-ws-input"
  end
end
