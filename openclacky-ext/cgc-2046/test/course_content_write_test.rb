# frozen_string_literal: true

# S4-extension 课程草稿写回路由测试:
# - POST /courses/:course_id/content 注册与透传(save_course_content,
#   base_version 乐观并发;版本流读侧 = GET content 顶层 version 透传)
# - body 校验:workspace_id / content / base_version 必填,base_version 必须整数 → 400
# - 乐观并发:上游 version_conflict: 错误 → 409 {error, message}(§B#23;宿主 client
#   包装为 "MCP server ... error on tools/call: <上游消息> (code -32000)",按子串匹配)
# - 未连接 → 503;其它上游 McpError → 502;意外 → 500
# - 面板 view.js 编辑器静态断言(v1 schema:goals/issues/checklist 子编辑器;
#   未知键无损往返;409 处理;R11 轮询条)
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/course_content_write_test.rb

require "minitest/autorun"
require "json"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")
require File.join(gem_spec.gem_dir, "lib/clacky/mcp/client")

require_relative "../api/handler"

class CourseContentWriteTest < Minitest::Test
  WS = "ws-uuid-1"
  COURSE = "course-uuid-1"
  CONTENT = {
    "goals" => ["g1"],
    "issues" => [{ "id" => "i1", "kind" => "handwork", "title" => "t", "story" => {} }]
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

  FakeReq = Struct.new(:body, :query, :header) do
    def headers
      header || {}
    end
  end

  # 宿主 openclacky gem 的真实包装(lib/clacky/mcp/client.rb:209,1.5.12 实证):
  # 上游 JSON-RPC error → ProtocolError("MCP server '<name>' error on tools/call:
  # <上游消息> (code -32000)")。测试一律用此形状——手搓无前缀消息是假绿(R1 P1-1)。
  def protocol_error(upstream_message)
    Clacky::Mcp::Client::ProtocolError.new(
      "MCP server 'cgc-2046' error on tools/call: #{upstream_message} (code -32000)")
  end

  # 宿主真实形态(course_routes_test 同款,smoke01 实证):
  #   @params = route pattern captures(symbol key,如 :course_id)
  #   POST body 在 req.body(JSON 字符串);GET query 在 req.query
  # advisor F2:写路由的面板同款头（json Content-Type + CSRF token）
  def write_headers
    { "Content-Type" => "application/json", "X-CGC-CSRF-Token" => Cgc2046Ext.csrf_token }
  end

  def build(registry:, body: nil, query: {}, params: {}, header: write_headers)
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

  def save(registry:, body:)
    invoke(:post, "/courses/:course_id/content",
           build(registry: registry, body: body, params: { course_id: COURSE }))
  end

  # ---- 路由注册 ----

  def test_save_route_registered
    assert_includes Cgc2046Ext.routes.map { |r| [r.method, r.pattern] },
                    [:post, "/courses/:course_id/content"]
  end

  # ---- 透传(合同形状:save_course_content,版本流) ----

  # 首存 base_version = 0;成功返回新 version
  def test_save_transfers_contract_and_returns_new_version
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate({ "course_id" => COURSE, "version" => 1 }) }] })

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 0 })

    assert_equal 200, halt.status
    body = JSON.parse(halt.payload)
    assert_equal true, body["ok"]
    assert_equal "save_course_content", body["tool"]
    assert_equal 1, body["result"]["version"]
    assert_equal [["cgc-2046", "save_course_content",
                   { "workspace_id" => WS, "course_id" => COURSE, "content" => CONTENT, "base_version" => 0 }]],
                 registry.calls
  end

  # 之后保存 base_version = 当前 version,整数原样下发
  def test_save_passes_current_base_version
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate({ "version" => 4 }) }] })

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 3 })

    assert_equal 200, halt.status
    assert_equal 3, registry.calls[0][2]["base_version"]
    assert_equal 4, JSON.parse(halt.payload)["result"]["version"]
  end

  # ---- body 校验 → 400(不下发 registry) ----

  def test_missing_workspace_id_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: { "content" => CONTENT, "base_version" => 0 })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "workspace_id"
    assert_empty registry.calls
  end

  def test_missing_content_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: { "workspace_id" => WS, "base_version" => 0 })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "content"
    assert_empty registry.calls
  end

  def test_non_object_content_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => "nope", "base_version" => 0 })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "content"
    assert_empty registry.calls
  end

  def test_missing_base_version_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "base_version"
    assert_empty registry.calls
  end

  def test_non_integer_base_version_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => "3" })

    assert_equal 400, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "base_version"
    assert_empty registry.calls
  end

  def test_empty_body_400
    registry = FakeRegistry.new

    halt = save(registry: registry, body: nil)

    assert_equal 400, halt.status
    assert_empty registry.calls
  end

  # ---- 乐观并发:version_conflict: → 409 ----

  def test_version_conflict_maps_409
    registry = FakeRegistry.new(error: protocol_error("version_conflict: draft is at version 5; re-read with get_course_content and retry"))

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 3 })

    assert_equal 409, halt.status
    body = JSON.parse(halt.payload)
    assert_equal "version_conflict", body["error"]
    assert_includes body["message"], "version 5"
  end

  # ---- 其它错误分层保持 503/502/500 ----

  def test_not_connected_503_with_hint
    registry = FakeRegistry.new(configured: false)

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 0 })

    assert_equal 503, halt.status
    body = JSON.parse(halt.payload)
    assert_includes body["error"], "not connected"
    assert_includes body["hint"], "连接"
    assert_empty registry.calls
  end

  # 同为宿主包装形状但不含 version_conflict: 子串 → 保持 502(钉住 include? 不误判)
  def test_other_mcp_error_stays_502
    registry = FakeRegistry.new(error: protocol_error("forbidden: not a tutor"))

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 0 })

    assert_equal 502, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "forbidden"
  end

  def test_unexpected_error_500
    registry = FakeRegistry.new(error: RuntimeError.new("surprise"))

    halt = save(registry: registry, body: { "workspace_id" => WS, "content" => CONTENT, "base_version" => 0 })

    assert_equal 500, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "course route failed"
  end

  # ---- GET content 顶层 version 透传(乐观并发读侧回归) ----

  def test_get_content_flows_top_level_version
    payload = { "course_id" => COURSE, "version" => 7, "goals" => [], "issues" => [] }
    registry = FakeRegistry.new(result: { "content" => [{ "text" => JSON.generate(payload) }] })

    halt = invoke(:get, "/courses/:course_id/content",
                  build(registry: registry, query: { "workspace_id" => WS }, params: { course_id: COURSE }))

    assert_equal 200, halt.status
    assert_equal 7, JSON.parse(halt.payload)["result"]["version"]
  end
end

# ---- 面板 view.js S4 静态断言(可测面;DOM 级留手动冒烟) ----

class CoursePanelEditTest < Minitest::Test
  # S2 教研拆出:编辑器整体迁移至 cgc-2046-curriculum 面板,锚随迁
  VIEW = File.read(File.expand_path("../panels/cgc-2046-curriculum/view.js", __dir__))
  COURSE_VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))

  def test_workspace_picker_replaces_uuid_input
    # S1 finding 收敛:按名选择器(数据源 /me/workspaces),用户永不手填 UUID
    assert_includes VIEW, 'id="cgt-course"'
    assert_includes VIEW, "/me/workspaces"
    refute_includes VIEW, "cgc-ws-input"
  end

  def test_edit_toggle_gated_by_roles
    # 教研权限按课程归属工作台判定(跨台角色:编辑入口随所选课程显隐);
    # 无权限卡仅在用户任何台都没有教研角色时出现
    assert_includes VIEW, 'data-testid="prep-edit-toggle"'
    assert_includes VIEW, "编辑内容"
    assert_includes VIEW, "canEditCourse"
    assert_includes VIEW, "hasAnyEditRole"
    assert_includes VIEW, '"tutor"'
    assert_includes VIEW, '"owner"'
    assert_includes VIEW, '"admin"'
    assert_includes VIEW, "无教研角色,只读"
    assert_includes VIEW, "function scopeOf(courseId)"
  end

  def test_draft_version_badge
    assert_includes VIEW, 'data-testid="prep-draft-version"'
    assert_includes VIEW, "草稿 v"
    # 版本号来自 get_course_content 结果顶层 version(编辑基准 draftContent)
    assert_includes VIEW, "draftContent.version"
  end

  def test_editor_shape_and_fields
    # v1 schema:goals 文本域 + issue 卡编辑器(kind/title/as_a/given/goal/materials/checklist)
    assert_includes VIEW, 'data-testid="curriculum-editor"'
    assert_includes VIEW, 'id="cgc-edit-goals"'
    assert_includes VIEW, 'data-f="kind"'
    assert_includes VIEW, "thoughtwork"
    assert_includes VIEW, "handwork"
    assert_includes VIEW, 'data-f="title"'
    assert_includes VIEW, 'data-f="as_a"'
    assert_includes VIEW, 'data-f="given"'
    assert_includes VIEW, 'data-f="goal"'
    assert_includes VIEW, 'data-f="materials"'
    assert_includes VIEW, 'data-f="checklist"'
    # 行内文档化的行格式
    assert_includes VIEW, "标题 | 链接"
    assert_includes VIEW, "id | 文本"
    # 新 issue 稳定 id + 删除按钮
    assert_includes VIEW, '"issue-" + Date.now()'
    assert_includes VIEW, "data-remove-issue"
  end

  def test_editor_preserves_unknown_keys
    # 无损往返:顶层合并在 draftContent 原文上(保留 course_title 等未编辑键);
    # issue/story 深拷贝对象原地改已知键,未知键不被编辑器丢弃
    assert_includes VIEW, "Object.assign({}, state.draftContent"
    assert_includes VIEW, "issue.story = issue.story || {}"
    assert_includes VIEW, "无损往返"
  end

  def test_save_posts_with_base_version
    assert_includes VIEW, 'method: "POST"'
    assert_includes VIEW, "base_version: draftVersion()"
    assert_includes VIEW, 'id="cgc-save"'
  end

  def test_conflict_banner_and_reload_on_409
    # AE2:409 → 红色横幅 + 丢弃本地编辑回只读视图
    assert_includes VIEW, "e.status === 409"
    assert_includes VIEW, 'data-testid="prep-conflict"'
    assert_includes VIEW, "内容已被他人更新到更新版本,本地编辑已丢弃;请重新进入编辑,基于最新草稿修改"
  end

  def test_prep_section_structure
    # S5 教研流程状态区迁移自 course 面板(prep_state/策略/违规/质量报告;只读透传)
    assert_includes VIEW, 'data-testid="prep-section"'
    assert_includes VIEW, 'data-testid="prep-state"'
    assert_includes VIEW, 'data-testid="prep-violations"'
    assert_includes VIEW, 'data-testid="prep-quality"'
    assert_includes VIEW, '"/prep"'
    assert_includes VIEW, "state.prep = null"
  end

  def test_focus_refresh_skips_rerender_while_editing
    # 焦点重拉在编辑态只更新快照不重渲染——renderEditor 用 state.draft 重建
    # DOM,未 collectEditor 的输入会丢(编辑保护)
    assert_includes VIEW, "document.addEventListener(\"visibilitychange\""
    assert_includes VIEW, "if (!state.editing && currentContainer) render()"
  end

  def test_unsaved_exit_guard
    # 教研拆出新增:取消编辑须确认(防误触丢稿)
    assert_includes VIEW, "放弃未保存的编辑内容?"
  end

  def test_read_markers_kept_on_learning_center
    # 学习中心(原列表/详情面)既有 testid 不丢
    assert_includes COURSE_VIEW, 'data-testid="panel-course-select"'
    assert_includes COURSE_VIEW, 'data-testid="panel-outline-node"'
    assert_includes COURSE_VIEW, 'data-testid="panel-resume-btn"'
    assert_includes COURSE_VIEW, 'data-testid="panel-not-connected"'
    assert_includes COURSE_VIEW, 'data-testid="panel-retry"'
  end

  def test_editor_escapes_server_strings
    assert_includes VIEW, "escapeHtml(issue.title"
    assert_includes VIEW, "escapeHtml(story.as_a"
    assert_includes VIEW, "escapeHtml(story.goal"
  end
end
