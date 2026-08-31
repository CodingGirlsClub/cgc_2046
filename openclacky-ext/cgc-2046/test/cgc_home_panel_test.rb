# frozen_string_literal: true

# 「程序媛汇 2046」hub 面板静态断言(S1-S4 重构)。
#
# hub 是唯一侧栏入口(sidebar.nav.top,替代已删除的 workspace 连接面板):
#   - 连接管理迁移:状态卡 / DELETE 断开(CSRF 自愈锚在 PanelCsrfSelfHealTest)/ 跳网站;
#   - 身份区 + Workspace 选择器 + 我的任务(沿用原 LS key,用户选择不丢);
#   - 角色感知功能目录:全员(和助手对话/发现活动/我的课程)+
#     tutor|owner|admin(教研工作台)+ platform_admin(平台管理);
#   - 一键进助手会话:POST /api/sessions {agent_profile}(青狮工作台同款通道);
#   - 事件订阅 tool_used / mcp_error。
#
# DOM 级驱动留手动冒烟(与发现/课程面板同口径);本文件钉可静态锚定的合同。
#
# 运行(需项目 mise 环境)：cd openclacky-ext/cgc-2046 && mise exec -- ruby test/cgc_home_panel_test.rb

require "minitest/autorun"

EXT_YML = File.read(File.expand_path("../ext.yml", __dir__))

class CgcHomePanelTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-home/view.js", __dir__))

  # ---- 注册与位置:唯一侧栏入口,挂顶部 ----
  def test_registers_home_workspace_and_top_nav
    assert_includes VIEW, 'const HOME_ID = "cgc"'
    assert_includes VIEW, "Clacky.ext.ui.registerWorkspace(HOME_ID"
    assert_includes VIEW, "程序媛汇 2046"
    # 顶部挂载(青狮工作台同款位置),不是底部 sidebar.nav
    assert_includes VIEW, 'Clacky.ext.ui.mount("sidebar.nav.top"'
    refute_includes VIEW, 'mount("sidebar.nav"', "hub 是唯一入口,不再挂底部导航位"
  end

  def test_ext_yml_registers_cgc_panel_without_workspace_panel
    assert_includes EXT_YML, "- id: cgc\n"
    assert_includes EXT_YML, "panels/cgc-home/view.js"
    assert_includes EXT_YML, "程序媛汇 2046"
    refute_includes EXT_YML, "panels/workspace/view.js", "S4:workspace 面板已删除"
    # 隐藏功能页仍注册(目录卡 openWorkspace 直达)
    assert_includes EXT_YML, "- id: cgc-2046-course"
    assert_includes EXT_YML, "- id: cgc-2046-discovery"
  end

  # ---- 连接管理迁移(原 workspace 面板职责) ----
  # 设计反馈:MCP 已连接 pill + 未连接态「连接助手」按钮 + 最近会话区
  def test_pill_and_connect_entry
    assert_includes VIEW, "MCP 已连接"
    assert_includes VIEW, 'discEl.dataset.mode === "connect"'
    assert_includes VIEW, "连接网站"
    assert_includes VIEW, "已断开连接,可点「连接网站」重新连接"
    # 副标题透出端点/Token(原状态卡信息不丢失)
    assert_includes VIEW, "Token 已配置"
  end

  # 连接网站:confirm → 创建会话 → 注入 CDP 自动连接请求(token 不进对话)
  def test_connect_website_flow
    assert_includes VIEW, "startConnectSession"
    assert_includes VIEW, "将自动打开 CGC 网站签发并复制 token"
    assert_includes VIEW, "injectIntoComposer"
    assert_includes VIEW, "CDP 自动连接"
    # contenteditable 注入 + 禁用按钮补发(cgc-learn 同款真机实证管道)
    assert_includes VIEW, "input.textContent = text"
    refute_includes VIEW, "input.value = text"
    assert_includes VIEW, "send.disabled"
  end

  def test_focus_refresh_reloads_workspaces
    # hub 焦点重拉:角色目录判定/身份区自动刷新;未连接态不拉
    assert_includes VIEW, 'document.addEventListener("visibilitychange"'
    assert_includes VIEW, "loadWorkspaces(currentContainer)"
    assert_includes VIEW, "!configured) return"
  end

  def test_recent_sessions_section
    assert_includes VIEW, '"/api/sessions?limit=50"'
    assert_includes VIEW, "s.agent_profile === AGENT_PROFILE"
    assert_includes VIEW, "Clacky.Router.navigate(\"session\""
    assert_includes VIEW, "cgc-recent-sessions"
    assert_includes VIEW, "is-running"
  end

  # 真机回归:WEBrick header 对未发送的键返回空数组(truthy),request_header
  # 的 || 链曾被空数组短路 → 带 Content-Type 的写请求也 415。钉死空数组剔除。
  def test_request_header_skips_empty_array_keys
    assert_includes VIEW, "body: \"{}\"", "DELETE 须带空 JSON body(fetch 规范:无 body 不发送 Content-Type)"
  end

  def test_connection_management_migrated
    assert_includes VIEW, 'API + "/status"'
    assert_includes VIEW, 'API + "/connect", { method: "DELETE"'
    assert_includes VIEW, "X-CGC-CSRF-Token"
    # 连接/token 状态收敛为 header 状态 pill(视觉重构);csrf 自愈与 web_url 保留
    assert_includes VIEW, "cgc-state-pill"
    assert_includes VIEW, "已连接"
    assert_includes VIEW, "csrf_token"
    assert_includes VIEW, "web_url"
  end

  def test_workspace_selection_keeps_storage_key
    # 沿用原 LS key:已连接用户的持久化选择不丢失
    assert_includes VIEW, '"cgc2046.workspacePanel.workspaceId"'
    assert_includes VIEW, "localStorage.getItem(LS_WORKSPACE)"
  end

  def test_tasks_and_identity_migrated
    assert_includes VIEW, 'API + "/me/workspaces"'
    assert_includes VIEW, 'API + "/tasks?workspace_id="'
    assert_includes VIEW, "is_platform_admin"
    assert_includes VIEW, "/settings/members"
  end

  # ---- 角色感知功能目录 ----
  def test_role_aware_catalog
    # 全员三卡
    assert_includes VIEW, "和助手对话"
    assert_includes VIEW, "发现活动"
    assert_includes VIEW, "我的课程"
    # 教研卡按角色显隐(tutor|owner|admin,与课程面板 EDIT_ROLES 同口径)
    assert_includes VIEW, 'const EDIT_ROLES = ["tutor", "owner", "admin"]'
    assert_includes VIEW, "教研工作台"
    # 平台管理卡按 is_platform_admin
    assert_includes VIEW, "平台管理"
    # 目录卡直达隐藏功能页
    assert_includes VIEW, 'const DISCOVERY_ID = "cgc-2046-discovery"'
    assert_includes VIEW, 'const COURSE_ID = "cgc-2046-course"'
    assert_includes VIEW, "Clacky.ext.ui.openWorkspace(spec.target)"
  end

  def test_unconnected_guide_renders_catalog_hint
    assert_includes VIEW, "cgc-connect-guide"
    assert_includes VIEW, "cgc2046-onboarding"
  end

  # ---- 一键进助手会话(青狮工作台同款通道) ----
  def test_assistant_session_launch
    assert_includes VIEW, 'const AGENT_PROFILE = "cgc-assistant"'
    assert_includes VIEW, '"/api/sessions"'
    assert_includes VIEW, "agent_profile: AGENT_PROFILE"
    assert_includes VIEW, "source: \"manual\""
    # 会话打开通道:Sessions API 优先,Router 兜底(宿主版本差异)
    assert_includes VIEW, "Clacky.Sessions.add(session)"
    assert_includes VIEW, "Clacky.Sessions.select(session.id)"
    assert_includes VIEW, 'Clacky.Router.navigate("session"'
    # 防重复点击
    assert_includes VIEW, "sessionBusy"
  end

  # ---- 事件订阅迁移(最近活动区) ----
  def test_event_subscriptions
    assert_includes VIEW, 'Clacky.ext.subscribe("ext.cgc-2046.tool_used"'
    assert_includes VIEW, 'Clacky.ext.subscribe("ext.cgc-2046.mcp_error"'
  end

  # ---- 安全纪律 ----
  def test_dynamic_values_escaped
    assert_includes VIEW, "function escapeHtml("
    assert_includes VIEW, "escapeHtml(spec.title)"
    assert_includes VIEW, "escapeHtml(spec.desc)"
    assert_includes VIEW, "escapeHtml(w.workspace_id)"
  end

  def test_no_token_render_surface
    refute_includes VIEW, "Authorization"
    # fetch 的请求头字样(headers:)允许存在,但不得触碰 MCP 条目的 headers/token 值
    refute_includes VIEW, "Bearer"
  end
end
# ---- 会话伴学侧栏(session.aside,attach cgc-assistant)静态断言 ----

# ---- CDP 自动连接 SOP 文档锚(skill/prompt 与面板注入指令三方一致) ----
class CdpAutoConnectDocsTest < Minitest::Test
  SKILL = File.read(File.expand_path("../skills/cgc2046-onboarding/SKILL.md", __dir__))
  PROMPT = File.read(File.expand_path("../agents/cgc-assistant/system_prompt.md", __dir__))
  VIEW = File.read(File.expand_path("../panels/cgc-home/view.js", __dir__))

  def test_skill_has_cdp_primary_path
    assert_includes SKILL, "首选路径：CDP 自动连接"
    assert_includes SKILL, "先清理旧 token"
    assert_includes SKILL, "用户手动创建的其它 token 绝不动"
    # 安全红线:点页面「复制」按钮,绝不读取/转述明文
    assert_includes SKILL, "点击「复制」"
    assert_includes SKILL, "绝不读取/转述明文"
    # 未登录提醒,不代填密码
    assert_includes SKILL, "不要替用户填账号密码"
    assert_includes SKILL, "回退"
  end

  def test_prompt_has_connect_sop
    assert_includes PROMPT, "连接请求（CDP 自动连接 SOP）"
    assert_includes PROMPT, "不要代填账号密码"
    assert_includes PROMPT, "点页面「复制」按钮"
    # 签发前撤销旧 auto token,且只动 openclacky-auto-* 命名(防误撤用户手工 token)
    assert_includes PROMPT, "openclacky-auto-*"
    assert_includes PROMPT, "撤销"
  end

  def test_panel_instruction_matches_sop
    assert_includes VIEW, "宿主自带的 browser 工具"
    assert_includes VIEW, "remote debugging"
    assert_includes VIEW, "绝不让 token 出现在对话或工具参数里"
    assert_includes VIEW, "回退 skill 的人工引导流程"
  end
end

# ---- P1 教研侧边栏 + 共创入口静态锚 ----
class TutorAsidePanelTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-2046-tutor-aside/view.js", __dir__))
  CURRICULUM_VIEW = File.read(File.expand_path("../panels/cgc-2046-curriculum/view.js", __dir__))
  PROMPT = File.read(File.expand_path("../agents/cgc-tutor/system_prompt.md", __dir__))

  def test_ext_yml_registers_tutor_agent_and_aside
    assert_includes EXT_YML, "- id: cgc-tutor"
    assert_includes EXT_YML, "agents/cgc-tutor/system_prompt.md"
    assert_includes EXT_YML, "- id: cgc-2046-tutor-aside"
    assert_includes EXT_YML, "attach: [cgc-tutor]"
  end

  def test_aside_mount_and_sync
    # attach cgc-tutor 的 session.aside;推拉结合(draft_saved/tool_used 事件 → 防抖拉)
    # + 10s 轮询兜底;version 签名变化才重渲染
    assert_includes VIEW, 'Clacky.ext.ui.mount("session.aside"'
    assert_includes VIEW, "agents: [AGENT]"
    assert_includes VIEW, 'ctx.agentProfile !== AGENT'
    assert_includes VIEW, 'subscribe("ext.cgc-2046.draft_saved"'
    assert_includes VIEW, 'subscribe("ext.cgc-2046.tool_used"'
    assert_includes VIEW, "POLL_MS = 10000"
    assert_includes VIEW, "function signature()"
  end

  def test_aside_shares_course_selection_and_scope
    # 与教研工作台共享课程选择 key;作用域按课程归属台
    assert_includes VIEW, "cgc2046.curriculum.courseId"
    assert_includes VIEW, "function scopeOf(courseId)"
    assert_includes VIEW, "在教研工作台打开"
  end

  def test_cocreate_entry_and_prep_stepper
    # 共创入口创建 cgc-tutor 会话并注入教研指令;prep 流程条展示态 + 推进走会话注入
    assert_includes CURRICULUM_VIEW, "coCreateWithTutor"
    assert_includes CURRICULUM_VIEW, 'agent_profile: "cgc-tutor"'
    assert_includes CURRICULUM_VIEW, "get_course_content 与 get_prep_status 读取现状"
    assert_includes CURRICULUM_VIEW, "prepStepper"
    assert_includes CURRICULUM_VIEW, 'data-testid="prep-stepper"'
    assert_includes CURRICULUM_VIEW, 'data-testid="prep-action"'
    assert_includes CURRICULUM_VIEW, "approve_prep"
    assert_includes CURRICULUM_VIEW, "request_changes_prep"
  end

  def test_tutor_prompt_sop
    # 教研 SOP:先读后写/渐进生成/409 合并重试/自评诚实/发布须 tutor 同意
    assert_includes PROMPT, "先读现状"
    assert_includes PROMPT, "渐进生成，不要一次全量"
    assert_includes PROMPT, "合并"
    assert_includes PROMPT, "自评要诚实"
    assert_includes PROMPT, "只在 tutor 明确同意后调用"
    assert_includes PROMPT, "绝不编造 UUID"
  end
end

class CgcLearnPanelTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-learn/view.js", __dir__))
  COURSE_VIEW = File.read(File.expand_path("../panels/cgc-course/view.js", __dir__))

  # 挂载合同:仅 CGC 助手会话(agents 过滤 + ctx 双保险);session.aside 是
  # TABBED_SLOT,必须带 tab(宿主 ext.js TABBED_SLOTS 约束)
  def test_session_aside_mount_contract
    assert_includes VIEW, 'Clacky.ext.ui.mount("session.aside"'
    assert_includes VIEW, "agents: [AGENT]"
    assert_includes VIEW, 'ctx.agentProfile !== AGENT'
    assert_includes VIEW, "tab: {"
    assert_includes VIEW, "学习地图"
  end

  def test_ext_yml_attaches_to_assistant
    assert_includes EXT_YML, "- id: cgc-2046-learn"
    assert_includes EXT_YML, "panels/cgc-learn/view.js"
    assert_includes EXT_YML, "attach: [cgc-assistant]"
  end

  # 注入管道(qingclaw sendLessonPrompt 同款):填输入框 + dispatch + 点发送;
  # 输入框缺失时兜底剪贴板/prompt,不得静默失败
  def test_inject_pipeline
    assert_includes VIEW, 'document.getElementById("user-input")'
    assert_includes VIEW, 'document.getElementById("btn-send")'
    # 宿主 #user-input 是 contenteditable DIV:textContent 注入(真机实证,
    # value 赋值 Composer.text 读不到);发送按钮禁用(订阅确认前)时待启用补发
    assert_includes VIEW, "input.textContent = text"
    refute_includes VIEW, "input.value = text"
    assert_includes VIEW, 'new Event("input", { bubbles: true })'
    assert_includes VIEW, "send.disabled"
    assert_includes VIEW, "send.click()"
    assert_includes VIEW, "navigator.clipboard.writeText"
  end

  # 指令口径分侧防漂移:learn 面板全口径(学习+到期复习);course 页 goLearn
  # 为泛学习入口(无 objective,七步循环口径),复习口吻归 learn 侧
  def test_prompt_copy_in_sync_with_course_panel
    %w[objective_id submit_learning_attempt 七步学习循环 rubric 全部 criterion id 到期复习].each do |key|
      assert_includes VIEW, key, "伴学面板指令缺关键句:#{key}"
    end
    %w[objective_id submit_learning_attempt 七步学习循环].each do |key|
      assert_includes COURSE_VIEW, key, "课程页 goLearn 指令缺关键句:#{key}"
    end
  end

  # 数据面:报名列表 + 学习状态;错误/空态收敛在面板内,不打扰会话
  def test_data_channels_and_states
    assert_includes VIEW, 'apiGet("/me/enrollments")'
    assert_includes VIEW, 'apiGet("/learning_state?workspace_id="'
    assert_includes VIEW, "data-testid=\"learn-error\""
    assert_includes VIEW, "data-testid=\"learn-empty\""
    assert_includes VIEW, "data-testid=\"learn-next\""
  end

  def test_dynamic_values_escaped
    assert_includes VIEW, "function escapeHtml("
    assert_includes VIEW, "escapeHtml(c.title)"
    assert_includes VIEW, "escapeHtml(o.title || o.id)"
    assert_includes VIEW, "escapeHtml(next.reason || next.objective_id)"
  end

  # 锁定目标不可点(无 data-inject),防越先修注入
  def test_locked_objectives_not_injectable
    assert_includes VIEW, '(locked ? "" : \' data-inject="'
  end
end
