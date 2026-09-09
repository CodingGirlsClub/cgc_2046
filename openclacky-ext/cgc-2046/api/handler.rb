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
#
# 数据面(各面板 → MCP 工具透传)收进 ROUTES 声明表：一条声明 = method + path +
# face + 工具名 + 字段契约，dispatch_route 统一走「guard → 逐字段 400 校验 →
# Cgc2046CourseRoutes.call_tool(503/502/500/409 分层)透传 → json」。
# 特殊路由(connect/status/skills sync/activity)非透传骨架，保持手写。

require "json"
require "securerandom"
require "uri"
require "fileutils"
require_relative "mcp_config"
require_relative "course_routes"
require_relative "../hooks/credential"

class Cgc2046Ext < Clacky::ApiExtension
  timeout 30

  # 条目名写死，防止 clobber mcp.json 中的任意条目
  SERVER_NAME = "cgc-2046"
  DESCRIPTION = "CGC-2046 platform capabilities"

  # advisor F2:进程级 CSRF token——写路由校验匹配;经 GET /status 同源下发
  # (跨站页面因 origin 收口读不到)。require "securerandom" 在文件头。
  def self.csrf_token
    @@csrf_token ||= SecureRandom.hex(32)
  end

  # POST /api/ext/cgc-2046/connect
  # body: { "token": "<必填>", "url": "<可选，缺省读 ext.yml config.mcp_url>" }
  # 校验后交给 Cgc2046McpConfig.connect_server 独占事务
  # （snapshot→upsert→原子提交→reload→失败逐字节回滚并二次 reload）。
  post "/connect" do
    guard_write!
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
    guard_origin!
    text = Cgc2046McpConfig.load_text(Cgc2046McpConfig.config_path)

    st = Cgc2046McpConfig.status_of(text, name: SERVER_NAME)
    # advisor F2:同源面板经此取 CSRF token（写路由请求头 X-CGC-CSRF-Token）
    json(ok: true, configured: st[:configured], url: st[:url], token_configured: st[:token_configured],
         web_url: config["web_url"], csrf_token: Cgc2046Ext.csrf_token)
  rescue Clacky::ApiExtension::Halt
    raise
  rescue StandardError => e
    error!("status failed: #{e.message}", status: 500)
  end

  # DELETE /api/ext/cgc-2046/connect
  # 移除 mcpServers["cgc-2046"] 条目并 reload MCP registry（断开连接）。
  # 事务（snapshot→remove→原子提交→reload→回滚）收在 Cgc2046McpConfig.disconnect_server。
  delete "/connect" do
    guard_write!
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
    guard_write!
    error!("skills sync ships in a later slice", status: 501)
  end

  # ── 数据面面孔:一族面板透传路由共享的 503 引导文案与 500 前缀 ──────────
  # (原 offering/workbench/learner_routes 单行转发浅层收编于此;
  #  管道本体 = Cgc2046CourseRoutes.call_tool 的 503/502/500/409 错误分层。)
  FACES = {
    course: {
      not_connected: Cgc2046CourseRoutes::NOT_CONNECTED,
      error_prefix: "course route failed"
    },
    offering: {
      not_connected: {
        error: "cgc-2046 MCP server not connected",
        hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用发现面板"
      }.freeze,
      error_prefix: "offering route failed"
    },
    workbench: {
      not_connected: {
        error: "cgc-2046 MCP server not connected",
        hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用工作台功能"
      }.freeze,
      error_prefix: "workbench route failed"
    },
    learner: {
      not_connected: {
        error: "cgc-2046 MCP server not connected",
        hint: "请先在 CGC-2046 面板完成连接(生成 token 并连接),再使用报名/支付功能"
      }.freeze,
      error_prefix: "learner route failed"
    }
  }.freeze

  # ── 数据面路由声明表(U6 发现 / U9 课程 / S1 工作台 / S4 草稿写回 / S5 教研 /
  #   S7·S8 learner / P1·P3 管理读面) ────────────────────────────────────
  # 字段契约:[源, key, 校验]
  #   源     :param — route_params_value(route capture + query 三层兜底,smoke01 实证:
  #                   真实宿主 GET query 不进 @params)
  #          :body  — json_body(string/symbol 双键;字符串字段 strip)
  #   校验   :pass     — 原样透传不查空(route capture 恒在,如 course_id)
  #          :required — 空 → 400 "<key> is required"
  #          :optional — 空不下发(缺省口径留服务端)
  #          :object   — 必须 Hash → "<key> must be an object"
  #          :integer  — 必须 Integer → "<key> must be an integer"
  #          { enum: [...] } — 枚举 → "<key> must be a or b"
  # conflict_409: true 时上游 version_conflict: → 409(S4 乐观并发,面板冲突 UX)。
  # missing_join: 收集全部缺参一次性报出(替代逐字段首个失败即报;
  #   两种报错口径与各路由原拷贝一一对应)。
  ROUTES = [
    # U9 课程内容(issue 卡集草稿;顶层 version 随透传自动流动 = S4 乐观并发读侧)
    { method: :get, path: "/courses/:course_id/content", face: :course, tool: "get_course_content",
      fields: [[:param, "course_id", :pass], [:param, "workspace_id", :required]] },
    # S4 课程草稿保存:base_version 必填整数(首存 0);版本冲突 → 409
    { method: :post, path: "/courses/:course_id/content", face: :course, tool: "save_course_content",
      conflict_409: true,
      fields: [[:body, "workspace_id", :required], [:param, "course_id", :pass],
               [:body, "content", :object], [:body, "base_version", :integer]] },
    # S5 教研流程状态;存量课程无 prep run 时上游报错,面板按 prep=null 处理
    { method: :get, path: "/courses/:course_id/prep", face: :course, tool: "get_prep_status",
      fields: [[:param, "course_id", :pass], [:param, "workspace_id", :required]] },
    # U6 公开浏览(KTD9:无 workspace_id 硬要求;四过滤参数可选,空值不下发,
    # 全缺省 = 服务端「近期」口径)
    { method: :get, path: "/offerings", face: :offering, tool: "list_public_offerings",
      fields: [[:param, "kind", :optional], [:param, "city", :optional],
               [:param, "starts_after", :optional], [:param, "starts_before", :optional]] },
    { method: :get, path: "/offerings/:id", face: :offering, tool: "get_public_offering",
      fields: [[:param, "id", :pass], [:param, "kind", :optional]] },
    # S1 工作台身份上下文
    { method: :get, path: "/me/workspaces", face: :workbench, tool: "list_my_workspaces" },
    # role 必填(平台管理模式 = platform_admin),workspace_id 可选
    { method: :get, path: "/playbook", face: :workbench, tool: "get_role_playbook",
      fields: [[:param, "role", :required], [:param, "workspace_id", :optional]] },
    { method: :get, path: "/tasks", face: :workbench, tool: "list_my_tasks",
      fields: [[:param, "workspace_id", :required]] },
    # S8 学习状态投影(objective 课程地图/先修锁/next_action/进度),两参必填
    { method: :get, path: "/learning_state", face: :learner, tool: "get_learning_state",
      fields: [[:param, "workspace_id", :required], [:param, "course_id", :required]] },
    # 启动(或幂等续学)学习 run:同版重进 resume,新版自动开新 run
    { method: :post, path: "/learning/start", face: :learner, tool: "start_learning_run",
      fields: [[:body, "workspace_id", :required], [:body, "course_id", :required]] },
    # 课程当前已发布版本详情;实证合同(UAT 真机 -32602):上游必填 workspace_id
    { method: :get, path: "/courses/:course_id/revision", face: :learner, tool: "get_course_revision",
      fields: [[:param, "course_id", :required], [:param, "workspace_id", :required]] },
    # 合并发现流(公开 ∪ 本人各 workspace 可访问,已去重);无参数
    { method: :get, path: "/discover", face: :learner, tool: "discover_offerings" },
    # 报名确认卡摘要:三参必填,缺参一次性报出(", " 连接)
    { method: :get, path: "/enrollment_summary", face: :learner, tool: "get_enrollment_summary",
      missing_join: ", ",
      fields: [[:param, "workspace_id", :required], [:param, "kind", :required],
               [:param, "offering_id", :required]] },
    # 创建报名(AE3 幂等:同一意图重放返回既有 enrollment,永不报错);
    # kind 枚举 event|course;reason/tier_id 可选,空不下发;
    # 收费条目返回 payment_pending + checkout_url,面板据此跳外部支付
    { method: :post, path: "/enrollments", face: :learner, tool: "create_enrollment",
      fields: [[:body, "workspace_id", :required], [:body, "kind", :required],
               [:body, "kind", { enum: %w[event course] }], [:body, "offering_id", :required],
               [:body, "reason", :optional], [:body, "tier_id", :optional]] },
    # 本人全部报名(AE8/R35):confirmed 课程报名 = 可学习课程;无参数
    { method: :get, path: "/me/enrollments", face: :learner, tool: "get_my_enrollments" },
    # 订单安全摘要(无渠道敏感数据)+ checkout_url;两参必填
    { method: :get, path: "/order_status", face: :learner, tool: "get_order_status",
      fields: [[:param, "workspace_id", :required], [:param, "enrollment_id", :required]] },
    # P1/P3 管理读面(含 draft):教研工作台课程发现面(#366)/ 活动供给区 /
    # 订单区(keyset 首页封顶 200,more 透传)/ 供给报名队列(三参必填," / " 连接)
    { method: :get, path: "/workspace/courses", face: :course, tool: "list_workspace_courses",
      fields: [[:param, "workspace_id", :required]] },
    { method: :get, path: "/workspace/events", face: :workbench, tool: "list_workspace_events",
      fields: [[:param, "workspace_id", :required]] },
    { method: :get, path: "/workspace/orders", face: :workbench, tool: "list_workspace_orders",
      fields: [[:param, "workspace_id", :required]] },
    { method: :get, path: "/workspace/enrollments", face: :workbench, tool: "list_enrollments",
      missing_join: " / ",
      fields: [[:param, "workspace_id", :required], [:param, "kind", :required],
               [:param, "offering_id", :required]] }
  ].freeze

  # 表驱动注册:路由列表与手写 DSL 完全同构(Cgc2046Ext.routes 25 条不变)
  ROUTES.each do |decl|
    send(decl[:method], decl[:path]) do
      dispatch_route(decl)
    end
  end

  # GET /api/ext/cgc-2046/activity
  # 最近 CGC 助手调用记录(历史回放):扫描宿主全部会话消息中
  # invoke_skill(skill_name=mcp:cgc-2046)的工具调用,匹配 role=tool 结果消息
  # 判定成败(subagent summary 含 "Subagent executed successfully" 为成功——
  # 与 hooks/after_tool_use 的实时事件互补:实时事件不落盘,本端点补历史)。
  # task 摘要截断 120 字符 + 凭证脱敏,时间倒序,最近 20 条。
  get "/activity" do
    guard_origin!
    items = []
    session_manager&.all_sessions&.each do |session|
      messages = session[:messages] || session["messages"] || []
      by_call_id = messages.each_with_object({}) do |m, acc|
        next unless (m[:role] || m["role"]).to_s == "tool"
        call_id = m[:tool_call_id] || m["tool_call_id"]
        acc[call_id] = (m[:content] || m["content"]).to_s
      end
      messages.each do |m|
        next unless (m[:role] || m["role"]).to_s == "assistant"
        Array(m[:tool_calls] || m["tool_calls"]).each do |tc|
          next unless tc.is_a?(Hash)
          fn = tc[:function] || tc["function"]
          next unless fn.is_a?(Hash)
          next unless (fn[:name] || fn["name"]).to_s == "invoke_skill"
          raw_args = fn[:arguments] || fn["arguments"]
          args = raw_args.is_a?(String) ? (JSON.parse(raw_args) rescue {}) : (raw_args || {})
          next unless args["skill_name"].to_s == "mcp:cgc-2046"
          call_id = tc[:id] || tc["id"]
          result_text = by_call_id[call_id].to_s
          ok = result_text.empty? || result_text.include?("Subagent executed successfully")
          items << {
            at: (m[:created_at] || m["created_at"]),
            status: ok ? "ok" : "error",
            task: redact_text(args["task"].to_s.gsub(/\s+/, " ")[0, 120])
          }
        end
      end
    end
    items.sort_by! { |i| -(i[:at].to_f) }
    json(ok: true, activity: items.first(20))
  end

  private

  # 声明表统一派发:guard → 逐字段校验装配参数 → call_tool 透传 → json。
  def dispatch_route(decl)
    decl[:method] == :post ? guard_write! : guard_origin!
    args = {}
    outcome = collect_route_args(decl, args)
    unless outcome
      face = FACES.fetch(decl[:face])
      outcome = Cgc2046CourseRoutes.call_tool(
        self, decl[:tool], args,
        not_connected: face[:not_connected],
        error_prefix: face[:error_prefix],
        conflict_409: decl[:conflict_409] || false
      )
    end
    json(outcome[:body], status: outcome[:status])
  end

  # 按 fields 声明顺序取值校验,装配 args;失败返回 { status: 400, body: },
  # 通过返回 nil。missing_join 声明的路由收集全部缺参一次性报出。
  def collect_route_args(decl, args)
    join = decl[:missing_join]
    missing = []
    (decl[:fields] || []).each do |(src, key, check)|
      value = route_field_value(src, key, check)
      case check
      when :pass
        args[key] = value
      when :required
        if value.empty?
          join ? (missing << key) : (return bad_request("#{key} is required"))
        else
          args[key] = value
        end
      when :optional
        args[key] = value unless value.empty?
      when :object
        return bad_request("#{key} must be an object") unless value.is_a?(Hash)
        args[key] = value
      when :integer
        return bad_request("#{key} must be an integer") unless value.is_a?(Integer)
        args[key] = value
      when Hash
        allowed = check.fetch(:enum)
        return bad_request("#{key} must be #{allowed.join(" or ")}") unless allowed.include?(value)
        args[key] = value
      end
    end
    return bad_request("#{missing.join(join)} is required") if join && missing.any?

    nil
  end

  def bad_request(message)
    { status: 400, body: { error: message } }
  end

  # 字段取值::param 走三层兜底(已 to_s,不 strip);:body 取 string/symbol
  # 双键,字符串字段 strip,object/integer 校验保留原始类型。
  def route_field_value(src, key, check)
    if src == :param
      route_params_value(key)
    else
      raw = json_body[key] || json_body[key.to_sym]
      (check == :object || check == :integer) ? raw : raw.to_s.strip
    end
  end

  # 凭证脱敏(与 hooks/credential 同一套正则;摘要进响应体前抹 Bearer/cgc_/裸 JWT)
  def redact_text(text)
    text.gsub(Cgc2046HookCredential::PATTERN, "<redacted>")
  end

  # ---- advisor F2:loopback 请求来源收口(CSRF/跨站借用/DNS rebinding 防线) ----
  # 宿主 http server 对 loopback peer 免 access key + CORS 全开(Allow-Origin: *
  # 且 preflight echo 任意 Origin),S7 起该通道可读跨台报名/订单、写报名——
  # 在扩展入口层收口:
  #   0) 所有路由:Host 必须是 loopback(127.0.0.0/8、localhost、[::1])——
  #      DNS rebinding 下浏览器带攻击者域名的 Host 头直连 127.0.0.1,若只做
  #      Origin==Host 同源比对会被整体绕过(读 /status 拿 CSRF token → 伪造
  #      connect 改写 mcp.json 指向攻击者 MCP server);宿主默认绑 127.0.0.1,
  #      合法请求 Host 只会是 loopback,缺失(HTTP/1.0)按失败关闭处理;
  #   1) 所有路由:Origin 存在时必须与 Host 同源(无 Origin 头的本地 curl/宿主
  #      内部调用放行),否则 403;
  #   2) 写路由(POST):Content-Type 必须 application/json(挡 text/plain 的
  #      cross-site simple request)+ CSRF token 匹配(进程级随机 token 经
  #      GET /status 同源下发;跨站页面读不到 /status——同为 origin 收口面)。
  #   3) 写路由含 DELETE(断开连接):同样是写端点,与 POST 同规——跨站页面
  #      可借宿主全开的 preflight 发出 cross-site DELETE,CSRF 一并拦截。
  # 注：同源为完整 origin 比对（scheme+host+port）——只比 host 挡不住本机
  #     异端口页面（localhost:8080 的恶意页可读 /status 拿 CSRF token 再
  #     伪造写请求；宿主 CORS 全开与 loopback 免认证不补此防线）。
  LOOPBACK_HOSTS = /\A(127(?:\.\d{1,3}){3}|localhost|::1|0:0:0:0:0:0:0:1)\z/

  def guard_origin!
    host = request_header("Host")
    json({ error: "host not allowed" }, status: 403) unless self.class.loopback_host?(host)

    origin = request_header("Origin")
    unless origin.nil? || origin.strip.empty?
      begin
        parsed = URI.parse(origin.strip)
      rescue URI::InvalidURIError
        parsed = nil
      end
      unless same_origin?(parsed, host)
        json({ error: "cross-origin request rejected" }, status: 403)
      end
    end
  end

  # 完整 origin 比对：scheme+host+port 逐项对齐请求实际协议与 Host 头（含端口）。
  # 宿主 WEBrick 仅明文 http 监听（无 TLS 配置），请求实际协议恒为 http——
  # https Origin 即跨源，403。host 去 IPv6 方括号后小写比对；端口取显式值，
  # Host 缺端口按 http 默认 80 归一（URI 侧 http 缺省端口同样归一为 80）。
  # 无 Origin 的本地 curl/宿主内部调用不进此方法，放行语义不变。
  def same_origin?(parsed, host_header)
    return false unless parsed.is_a?(URI::HTTP) && parsed.host && parsed.scheme == "http"

    h_host, h_port = self.class.split_host_header(host_header)
    return false if h_host.nil?

    parsed.hostname.downcase == h_host &&
      parsed.port == (h_port ? h_port.to_i : URI::HTTP.default_port)
  end

  # Host 头拆分为 [host, port]：IPv6 方括号内为完整 host，冒号后为端口；
  # host 已小写，port 为字符串或 nil（Host 缺端口）；裸 IPv6（无括号）
  # 按冒号切开必然比对失败——失败关闭，合法浏览器恒用方括号形态。
  def self.split_host_header(host_header)
    s = host_header.strip.downcase
    if s.start_with?("[")
      close = s.index("]")
      return [nil, nil] unless close

      rest = s[(close + 1)..]
      [s[1...close], rest.start_with?(":") ? rest[1..] : nil]
    else
      s.split(":", 2)
    end
  end

  # Host 头判定:剥端口/IPv6 方括号后必须落在 loopback 集合。
  # 挂 class 方法——单测直接断言判定表,不经路由。
  def self.loopback_host?(host_header)
    return false if host_header.nil?

    h = host_header.strip.downcase
    return false if h.empty?

    if h.start_with?("[")
      # [::1]:7070 / [::1] → ::1
      h = h.sub(/:\d+\z/, "").delete_prefix("[").delete_suffix("]")
    elsif h.count(":") <= 1
      h = h.sub(/:\d+\z/, "")
    end
    # 裸 IPv6(无括号)不剥端口——冒号数 >1 时按完整地址处理
    h.match?(LOOPBACK_HOSTS)
  end

  def guard_write!
    guard_origin!
    ctype = request_header("Content-Type").to_s
    unless ctype.include?("application/json")
      json({ error: "Content-Type must be application/json" }, status: 415)
    end
    token = request_header("X-CGC-CSRF-Token")
    unless token.is_a?(String) && secure_compare(token, Cgc2046Ext.csrf_token)
      json({ error: "missing or invalid CSRF token" }, status: 403)
    end
  end

  # 常量时间字符串比较（对齐宿主 http_server.rb secure_compare 先例；
  # loopback 场景实际不可利用，防御性对齐——advisor R2 advisory 2）
  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize
    res = 0
    a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
    res.zero?
  end

  # req.headers 兼容层:宿主 WEBrick req 是 #header(Rack 风格小写键);
  # 测试 FakeReq 自带同形方法
  def request_header(name)
    h = req.respond_to?(:header) ? req.header : (req.respond_to?(:headers) ? req.headers : {})
    return nil if h.nil?
    # WEBrick header 对未发送的键返回空数组(truthy)——直接 || 链会被空数组
    # 短路,必须先剔除空值再取第一个候选
    v = [h[name], h[name.downcase], h[name.upcase],
         h[name.to_sym], h[name.downcase.to_sym]]
        .compact
        .reject { |x| x.is_a?(Array) && x.empty? }
        .first
    v = v.first if v.is_a?(Array)
    v.is_a?(String) ? v : nil
  end

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
end
