# frozen_string_literal: true

# CGC-2046 连接器扩展 API handler。
# 挂载前缀 /api/ext/cgc-2046/（由 ApiExtensionDispatcher 自动添加），热加载无需重启。
#
# 安全红线：token 只允许写入 ~/.clacky/mcp.json；任何路径不得把 token
# 写进响应体、日志或 data_path 文件。
#
# 写入加固：读-merge-写-reload 事务收在 Cgc2046McpConfig（connect_server/disconnect_server，
# 模块级互斥 + 0600 排他 tmp + 原子 rename；reload 失败逐字节回滚并二次 reload）。
# 本 adapter 只保留请求校验与结果翻译。

require "json"
require "fileutils"
require_relative "mcp_config"
require_relative "course_routes"
require_relative "offering_routes"
require_relative "workbench_routes"
require_relative "learner_routes"

class Cgc2046Ext < Clacky::ApiExtension
  timeout 30

  # 条目名写死，防止 clobber mcp.json 中的任意条目
  SERVER_NAME = "cgc-2046"
  DESCRIPTION = "CGC-2046 platform capabilities"

  # POST /api/ext/cgc-2046/connect
  # body: { "token": "<必填>", "url": "<可选，缺省读 ext.yml config.mcp_url>" }
  # 校验后交给 Cgc2046McpConfig.connect_server 独占事务
  # （snapshot→upsert→原子提交→reload→失败逐字节回滚并二次 reload）。
  post "/connect" do
    body  = json_body
    token = (body["token"] || body[:token]).to_s.strip

    error!("token is required", status: 422) if token.empty?
    error!("token must be at most 512 characters", status: 422) if token.length > 512

    url = (body["url"] || body[:url]).to_s.strip
    url = config["mcp_url"].to_s.strip if url.empty?
    error!("mcp url is not configured", status: 422) if url.empty?
    error!("mcp url must start with http:// or https://", status: 422) unless url.match?(%r{\Ahttps?://})

    # 注入 reloader：把宿主私有 registry 翻译成 callable（nil-safe：registry 惰性创建，
    # 尚未创建时 reload 是 no-op，下次用到会读新文件）
    reloader = -> { @http_server&.send(:mcp_registry)&.reload }

    result = Cgc2046McpConfig.connect_server(
      name: SERVER_NAME,
      spec: {
        "type"        => "http",
        "url"         => url,
        "headers"     => { "Authorization" => "Bearer #{token}" },
        "description" => DESCRIPTION
      },
      reloader: reloader
    )

    json(ok: true, created: result[:created], url: url)
  rescue Clacky::ApiExtension::Halt
    # helper（json/error!）通过 Halt 结束请求，必须放行，否则会被下面的 500 吞掉
    raise
  rescue StandardError => e
    error!("connect failed: #{e.message}", status: 500)
  end

  # GET /api/ext/cgc-2046/status
  # 返回配置状态；绝不返回 headers / token。
  get "/status" do
    text = Cgc2046McpConfig.load_text(Cgc2046McpConfig.config_path)

    st = Cgc2046McpConfig.status_of(text, name: SERVER_NAME)
    json(ok: true, configured: st[:configured], url: st[:url], token_configured: st[:token_configured],
         web_url: config["web_url"])
  rescue Clacky::ApiExtension::Halt
    raise
  rescue StandardError => e
    error!("status failed: #{e.message}", status: 500)
  end

  # DELETE /api/ext/cgc-2046/connect
  # 移除 mcpServers["cgc-2046"] 条目并 reload MCP registry（断开连接）。
  # 事务（snapshot→remove→原子提交→reload→回滚）收在 Cgc2046McpConfig.disconnect_server。
  delete "/connect" do
    # 注入 reloader：把宿主私有 registry 翻译成 callable（nil-safe）
    reloader = -> { @http_server&.send(:mcp_registry)&.reload }

    result = Cgc2046McpConfig.disconnect_server(name: SERVER_NAME, reloader: reloader)
    json(ok: true, removed: result[:removed])
  rescue Clacky::ApiExtension::Halt
    # helper（json/error!）通过 Halt 结束请求，必须放行
    raise
  rescue StandardError => e
    error!("disconnect failed: #{e.message}", status: 500)
  end

  # POST /api/ext/cgc-2046/skills/sync
  # 端点骨架（D11 留位）：全量/增量同步在后续切片交付。
  post "/skills/sync" do
    error!("skills sync ships in a later slice", status: 501)
  end

  # ── U9 课程学习面板数据面(读透传 + S4 草稿写回;学习评价写回发生在 session) ──
  # workspace_id 为必填 query(平台 D12 无状态作用域);面板侧经选择器记忆。

  # GET /api/ext/cgc-2046/courses?workspace_id=...
  # 我的课程列表:透传 MCP get_learning_records(本人全部课程记录,面板按
  # course_id 分组推导课程列表)。
  get "/courses" do
    outcome = course_tool("get_learning_records", {})
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/courses/:course_id/content?workspace_id=...
  # 课程内容(issue 卡集草稿):透传 MCP get_course_content。
  # 结果顶层 version 随透传自动流动(S4 乐观并发的读侧)。
  get "/courses/:course_id/content" do
    outcome = course_tool("get_course_content", { "course_id" => route_params_value("course_id") })
    json(outcome[:body], status: outcome[:status])
  end

  # POST /api/ext/cgc-2046/courses/:course_id/content
  # 课程草稿保存(S4-extension):透传 MCP save_course_content。
  # body { workspace_id, content, base_version } 皆必填,base_version 必须整数
  # (首存 0,之后为当前版本);版本冲突 → 409(面板据此加载最新草稿并提示重编)。
  post "/courses/:course_id/content" do
    body         = json_body
    workspace_id = (body["workspace_id"] || body[:workspace_id]).to_s.strip
    content      = body["content"] || body[:content]
    base_version = body["base_version"] || body[:base_version]

    outcome =
      if workspace_id.empty?
        { status: 400, body: { error: "workspace_id is required" } }
      elsif !content.is_a?(Hash)
        { status: 400, body: { error: "content must be an object" } }
      elsif !base_version.is_a?(Integer)
        { status: 400, body: { error: "base_version must be an integer" } }
      else
        Cgc2046CourseRoutes.call_course_save_tool(self, {
          "workspace_id" => workspace_id,
          "course_id"    => route_params_value("course_id"),
          "content"      => content,
          "base_version" => base_version
        })
      end
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/courses/:course_id/records?workspace_id=...
  # 本人该课程学习记录:透传 MCP get_learning_records(course_id 过滤)。
  get "/courses/:course_id/records" do
    outcome = course_tool("get_learning_records", { "course_id" => route_params_value("course_id") })
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/courses/:course_id/prep?workspace_id=...
  # 课程教研流程状态(role-agent-journeys-v2 S5-extension):透传 MCP get_prep_status。
  # 课程无 prep run(存量课程)时上游报「no preparation run found」——面板按
  # prep=null 处理(不置错误态),仅 canEdit 视图拉取本端点。
  get "/courses/:course_id/prep" do
    outcome = course_tool("get_prep_status", { "course_id" => route_params_value("course_id") })
    json(outcome[:body], status: outcome[:status])
  end

  # ── U6 发现面板数据面(公开浏览,纯读透传;无需 workspace_id,KTD9) ──────────

  # GET /api/ext/cgc-2046/offerings?kind=&city=&starts_after=&starts_before=
  # 公开活动/课程列表:透传 MCP list_public_offerings。四个过滤参数皆可选,
  # 空值不下发;全缺省 = 服务端「近期」口径(未来条目 + 时间待定条目)。
  get "/offerings" do
    outcome = Cgc2046OfferingRoutes.call_offering_tool(self, "list_public_offerings", offering_filters)
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/offerings/:id?kind=
  # 单个公开条目详情:透传 MCP get_public_offering(id 必填走 route capture,kind 可选)。
  get "/offerings/:id" do
    args = { "id" => route_params_value("id") }
    kind = route_params_value("kind")
    args["kind"] = kind unless kind.empty?
    outcome = Cgc2046OfferingRoutes.call_offering_tool(self, "get_public_offering", args)
    json(outcome[:body], status: outcome[:status])
  end

  # ── S1-extension 工作台数据面(身份上下文;纯读透传) ─────────────────────
  # query 读取走 route_params_value 三层兜底(真实宿主 GET query 不进 @params)。

  # GET /api/ext/cgc-2046/me/workspaces
  # 本人可访问 Workspace 列表 + 各处角色 + is_platform_admin:
  # 透传 MCP list_my_workspaces(无参数)。
  get "/me/workspaces" do
    outcome = Cgc2046WorkbenchRoutes.call_workbench_tool(self, "list_my_workspaces", {})
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/playbook?role=...&workspace_id=...
  # 角色工作模式 playbook:透传 MCP get_role_playbook。
  # role 必填(平台管理模式 = platform_admin),workspace_id 可选。
  get "/playbook" do
    role = route_params_value("role")
    if role.empty?
      outcome = { status: 400, body: { error: "role is required" } }
    else
      args = { "role" => role }
      workspace_id = route_params_value("workspace_id")
      args["workspace_id"] = workspace_id unless workspace_id.empty?
      outcome = Cgc2046WorkbenchRoutes.call_workbench_tool(self, "get_role_playbook", args)
    end
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/tasks?workspace_id=...
  # 本人在该 Workspace 的待办列表:透传 MCP list_my_tasks(workspace_id 必填)。
  get "/tasks" do
    workspace_id = route_params_value("workspace_id")
    if workspace_id.empty?
      outcome = { status: 400, body: { error: "workspace_id is required" } }
    else
      outcome = Cgc2046WorkbenchRoutes.call_workbench_tool(self, "list_my_tasks", { "workspace_id" => workspace_id })
    end
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/discover
  # 合并发现流(公开 ∪ 本人各 workspace 可访问,逐条按可见性过滤,已去重):
  # 透传 MCP discover_offerings(无参数)。
  get "/discover" do
    outcome = Cgc2046LearnerRoutes.call_learner_tool(self, "discover_offerings", {})
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/enrollment_summary?workspace_id=&kind=&offering_id=
  # 报名确认卡摘要(目标/价格/策略/deadline/将创建的 enrollment 状态):
  # 透传 MCP get_enrollment_summary。三参数皆必填,缺一 → 400(不下发 registry)。
  get "/enrollment_summary" do
    args = {}
    missing = []
    %w[workspace_id kind offering_id].each do |key|
      value = route_params_value(key)
      if value.empty?
        missing << key
      else
        args[key] = value
      end
    end
    outcome =
      if missing.any?
        { status: 400, body: { error: "#{missing.join(", ")} is required" } }
      else
        Cgc2046LearnerRoutes.call_learner_tool(self, "get_enrollment_summary", args)
      end
    json(outcome[:body], status: outcome[:status])
  end

  # POST /api/ext/cgc-2046/enrollments
  # 创建报名(幂等:同一意图重放返回既有 enrollment,永不报错——AE3):
  # 透传 MCP create_enrollment。body { workspace_id, kind, offering_id } 必填,
  # kind 枚举 event|course;reason/tier_id 可选,空值不下发。
  # 收费条目返回 payment_pending + checkout_url(web 结算页),面板据此跳外部支付。
  post "/enrollments" do
    body         = json_body
    workspace_id = (body["workspace_id"] || body[:workspace_id]).to_s.strip
    kind         = (body["kind"] || body[:kind]).to_s.strip
    offering_id  = (body["offering_id"] || body[:offering_id]).to_s.strip

    outcome =
      if workspace_id.empty?
        { status: 400, body: { error: "workspace_id is required" } }
      elsif kind.empty?
        { status: 400, body: { error: "kind is required" } }
      elsif !%w[event course].include?(kind)
        { status: 400, body: { error: "kind must be event or course" } }
      elsif offering_id.empty?
        { status: 400, body: { error: "offering_id is required" } }
      else
        args = { "workspace_id" => workspace_id, "kind" => kind, "offering_id" => offering_id }
        reason  = (body["reason"] || body[:reason]).to_s.strip
        tier_id = (body["tier_id"] || body[:tier_id]).to_s.strip
        args["reason"] = reason unless reason.empty?
        args["tier_id"] = tier_id unless tier_id.empty?
        Cgc2046LearnerRoutes.call_learner_tool(self, "create_enrollment", args)
      end
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/me/enrollments
  # 本人全部报名(所有状态,跨 workspace):透传 MCP get_my_enrollments(无参数)。
  # 课程面板列表数据源(AE8/R35):confirmed 课程报名 = 可学习课程
  # (新报名零学习记录也必须出现);pending/payment_pending 入「报名进行中」区。
  get "/me/enrollments" do
    outcome = Cgc2046LearnerRoutes.call_learner_tool(self, "get_my_enrollments", {})
    json(outcome[:body], status: outcome[:status])
  end

  # GET /api/ext/cgc-2046/order_status?workspace_id=&enrollment_id=
  # 订单安全摘要(金额/状态/过期时间,无渠道敏感数据)+ checkout_url:
  # 透传 MCP get_order_status。两参数皆必填,缺一 → 400。
  get "/order_status" do
    workspace_id  = route_params_value("workspace_id")
    enrollment_id = route_params_value("enrollment_id")
    outcome =
      if workspace_id.empty?
        { status: 400, body: { error: "workspace_id is required" } }
      elsif enrollment_id.empty?
        { status: 400, body: { error: "enrollment_id is required" } }
      else
        Cgc2046LearnerRoutes.call_learner_tool(self, "get_order_status",
                                               { "workspace_id" => workspace_id, "enrollment_id" => enrollment_id })
      end
    json(outcome[:body], status: outcome[:status])
  end

  private

  # 路由/查询参数读取:三层兜底——
  #   1. @params:宿主 dispatcher 注入的 route captures(symbol key,:course_id)
  #   2. @params string key(测试 allocate 路径同构注入)
  #   3. query:GET query string(ApiExtension#query → req.query)
  # 冒烟发现(smoke01):真实宿主 GET query 不进 @params,必须走 query。
  def route_params_value(key)
    p = @params
    v = p.is_a?(Hash) ? (p[key] || p[key.to_sym] || p[key.to_s]) : nil
    v = query[key] if v.nil? || v.to_s.empty?
    v.to_s
  end

  # 组装 workspace_id(query 必填)+ 透传;缺参 → 400 引导
  def course_tool(tool_name, extra)
    workspace_id = route_params_value("workspace_id").to_s
    return { status: 400, body: { error: "workspace_id is required" } } if workspace_id.empty?

    Cgc2046CourseRoutes.call_course_tool(
      self,
      tool_name,
      extra.merge("workspace_id" => workspace_id)
    )
  end

  # 发现列表过滤参数收集:kind/city/starts_after/starts_before 皆可选,空串不下发
  def offering_filters
    %w[kind city starts_after starts_before].each_with_object({}) do |key, args|
      value = route_params_value(key)
      args[key] = value unless value.empty?
    end
  end
end
