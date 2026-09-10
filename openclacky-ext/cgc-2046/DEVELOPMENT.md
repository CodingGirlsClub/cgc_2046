# cgc-2046 扩展开发文档

面向本仓库的开发与验收；用户文档见 [README.md](README.md)，更新记录见 [CHANGELOG.md](CHANGELOG.md)。本文件不进 ext pack 分发包（见 `.gitignore`）。

## 架构概览

CGC-2046 是 CGC OpenClacky 内置的连接器扩展：把 CGC-2046 工作台接入本机 agent。安装后提供：

- **API 端点**：`POST /api/ext/cgc-2046/connect` 把 token + MCP URL 原子化 read-merge-write 进 `~/.clacky/mcp.json`（统一收紧 0600——重写既有文件不继承宽松 mode，类级互斥锁防并发，reload 失败自动回滚）并热重载 MCP registry；`GET /api/ext/cgc-2046/status` 查询配置状态（`configured` / `url` / `token_configured` / `web_url`，不泄漏 token）；`DELETE /api/ext/cgc-2046/connect` 断开连接（移除 `cgc-2046` 条目 + reload，同样原子写与回滚加固）。全部路由做 Origin/Host 同源校验（无 Origin 的本地 curl 放行）；写路由（POST 及 `DELETE /connect`——同为写端点，跨站可借宿主全开的 preflight 发出 cross-site DELETE）另需 `Content-Type: application/json` + `X-CGC-CSRF-Token`（进程级 token 经 `GET /status` 同源下发，防跨站伪造写——尤其 connect 可改写 mcp.json 指向）；`GET /api/ext/cgc-2046/offerings` 与 `GET /api/ext/cgc-2046/offerings/:id` 透传公开浏览工具（`list_public_offerings` / …
- **panel**：`cgc`——「程序媛汇 2046」hub 面板（唯一侧栏入口，挂 `sidebar.nav.top` 顶部）：连接管理（状态 / 断开 / 跳转网站）+ 身份区（角色徽章 / Workspace 选择器 / 管理入口）+ 我的任务 + 角色感知功能目录（全员：和助手对话 / 发现活动 / 我的课程；tutor 加教研工作台；owner/admin 加工作台管理；platform_admin 加平台管理）+ 最近会话（三助手 Tab 过滤，点击继续）。`cgc-2046-course` 与 `cgc-2046-discovery` 为**隐藏功能页**（无侧栏入口，hub 目录卡 `openWorkspace` 直达，页头「← 返回工作台」闭环）：前者是课程学习面板（课程地图 / 草稿编辑 / 待复习队列），后者是发现面板（公开活动/课程列表 + 报名 + 支付轮询）。管理会话右侧挂 `cgc-2046-admin-aside`（`session.aside`，attach `cgc-admin`）：待办审批（跨台聚合，行可点注入处理指令）+ 供给区（课程+活动统一投影、kind 徽章，行点击下钻报名队列，待审批/待支付行注入；展开区动作排按状态门渲染——draft 可发布/取消、open 可结束/取消，注入带 id 指令走 agent 确认流；「✎ 对话修改」注入单字段轻改、「↗ 网站编辑」深链 web 详情页承接重编辑）+ 订单区（注意力面：只渲染非终态，退款失败置顶，帽 5 行 + 尾行引导问助手；终态与帽外订单走 agent/web）+ 按域分组快捷入口（供给/成员/财务，含创建课程/活动）+ 网站管理页深链（成员/权限/支付等重 UI 域跳 web 不重造）；侧栏纯读投影 + …
- **agents**：`cgc-assistant`、`cgc-tutor`、`cgc-admin` 都先选择可信 Workspace，再在启动时拉取平台当前部署的角色 playbook 并展示版本。`cgc-tutor` 与 `cgc-admin` 是安全薄壳：角色方法与工具说明由平台下发，扩展只保留 OpenClacky 入口和不可覆盖的安全纪律；前者在教材章节边界重拉 tutor playbook，后者只拉 workspace_admin playbook。三者仍随同一个 AGPL-3.0-only 扩展分发。
- **skill**：`cgc2046-onboarding`——首选面板触发的浏览器/CDP 自动连接（面板「连接网站」→ 注入 `cgc-assistant` → 接管真实浏览器 → 自动签发一次性 token → stdin 管道调 connect → 验证 status 与 MCP 握手）；自动路径不可用时退回剪贴板管道 / 临时文件 / 对话粘贴（最后手段）三级 fallback，细节见 `skills/cgc2046-onboarding/references/connection-procedure.md`。
- **教研配套视频**：制作方法为平台侧私有 tutor playbook 增量（不随扩展分发）；扩展只携带执行物料（场景模板 / 环境自检 / TTS 脚本 / 品牌素材，见 `agents/cgc-tutor/video/`）。
- **hooks**（OpenClacky ≥1.5.7 事件能力）：
  - `after_tool_use`——主 agent 每次调用 CGC MCP server（virtual skill `mcp:cgc-2046`，条目名与扩展 id 统一）后推 `ext.cgc-2046.tool_used` 事件（成功 persist: true 进消息流，失败仅实时提示）；subagent 内 curl 连接失败不抛异常、错误文本藏在 subagent summary 里——文本特征命中（MCP server 'cgc 前缀 / Connection refused / Failed to open TCP / localhost:4102 等具体形态）时另推 `ext.cgc-2046.mcp_error`（错误片段先抹凭证再截断，覆盖 Bearer / cgc_ 前缀 / 裸 JWT 形态）。
  - `on_tool_error`——防御性：工具调用真正抛异常且错误与 CGC MCP 连接相关时推 `ext.cgc-2046.mcp_error`（当前 agent 侧 MCP 走 virtual skill + curl 路径，一般不触发）。
- **面板事件订阅**：hub 面板订阅 `mcp_error` 渲染连接异常横幅；`tool_used`/`draft_saved` 由管理/教研侧栏消费驱动刷新闭环。

要求 **openclacky >= 1.3.7**（api handler / ext pack / install 能力自 v1.3.7 引入）。

## 目录结构

```
openclacky-ext/cgc-2046/
  ext.yml                          # manifest（id 与目录名一致；config.mcp_url 是唯一改 URL 的点）
  api/
    handler.rb                     # 路由骨架：connect/status/version/skills sync 手写 + error! 惯例 + origin/CSRF 收口；
                                   #   透传数据面收进 ROUTES 声明表（原 offering/workbench/learner_routes 已并入）
    mcp_config.rb                  # mcp.json read-merge-write 纯逻辑（不依赖 clacky gem，含原子写）
    course_routes.rb               # 共享 call_tool 管道（503/502/500 分层，409 冲突映射）+ 课程数据面；
                                   #   offering/workbench/learner 透传路由共用该管道
  panels/
    shared/view.js                 # 面板共享骨架（loopback 封装/CSRF 自愈/注入管道/轮询/材料渲染；
                                   #   首位声明先注入 window.CgcKit，无 attach 不显示）
    cgc-home/view.js               # 「程序媛汇 2046」hub（唯一入口:连接/身份/任务/角色目录/助手会话）
    cgc-course/view.js             # 课程学习隐藏功能页（列表/详情/草稿编辑/轮询）
    cgc-2046-curriculum/view.js    # 教研工作台面板（草稿编辑器 + prep 流程，tutor 入口）
    cgc-discovery/view.js          # 发现隐藏功能页（合并流 + 报名确认卡 + 支付轮询）
    cgc-learn/view.js              # 学习地图（attach cgc-assistant：目标地图/待复习/一键注入会话）
    cgc-2046-tutor-aside/view.js   # 教研侧栏（attach cgc-tutor：草稿树/版本/prep 状态实时同步）
    cgc-2046-admin-aside/view.js   # 管理侧栏（attach cgc-admin：待办审批/供给/订单/快捷入口/深链）
  agents/
    cgc-assistant/system_prompt.md # 通用工作台助手
    cgc-tutor/system_prompt.md     # tutor playbook 安全薄壳（章节边界重拉）
    cgc-admin/system_prompt.md     # workspace_admin playbook 安全薄壳
    cgc-tutor/video/               # 教研配套视频执行物料（方法见平台侧私有 playbook 增量）
      scene_template.py            # 16:9 场景骨架
      check_env.sh                 # Manim/TTS/ffmpeg/LaTeX/品牌素材自检
      scripts/fish_tts.py          # Fish Audio TTS（stdlib）
      assets/                      # CGC 品牌 logo（品牌卡 / 角标）
  skills/cgc2046-onboarding/
    SKILL.md                       # 连接引导流程（面板一键连接主流程 + fallback 路由）
    references/connection-procedure.md # 连接步骤参考（CDP SOP / 剪贴板 / 临时文件 / 对话粘贴）
  hooks/
    after_tool_use.rb              # CGC MCP 调用后推 tool_used / mcp_error 事件
    on_tool_error.rb               # 工具异常文本命中 CGC 形态时推 mcp_error 事件
    credential.rb                  # 两 hook 共享的凭证脱敏正则
  bin/pack                         # 打包脚本（symlink → ext pack → ext verify）；随 repo 不入包（.gitignore 排除）
  bin/check-version-bump           # 版本纪律门禁（内容指纹变了就必须 bump ext.yml version）；deploy CI 调用，可本地跑
  test/                            # 测试随 repo 不入包（.gitignore 排除，见「测试」一节）
    mcp_config_test.rb             # 纯逻辑单测（minitest，stdlib）
    handler_routes_test.rb         # 请求级测试（fake req + Halt 捕获，不落盘）
    offering_routes_test.rb        # 发现路由 + 面板/prompt 静态断言（FakeRegistry + allocate 先例）
    course_routes_test.rb          # 课程路由（call_tool 管道与错误分层）
    course_content_write_test.rb   # 草稿写路径（协议错误/409 冲突）
    workbench_routes_test.rb       # 工作台路由
    hooks_test.rb                  # 生命周期钩子
    learner_journey_routes_test.rb # Learner 路由 + guard 收口 + 面板静态断言（S7）
    video_pipeline_assets_test.rb  # 视频物料契约（模板/自检/素材/key 安全）
    cgc_home_panel_test.rb         # hub 面板静态断言（注册/目录/会话通道/安全纪律）
    panel_behavior_harness.js      # 面板行为级 harness（node 驱动 view.js，DOM 断言）
```

## 打包与安装

```bash
# 打包（产物在 openclacky-ext/dist/，已 gitignore）
openclacky-ext/cgc-2046/bin/pack

# 开发/验收安装
openclacky ext install openclacky-ext/dist/cgc-2046.zip
```

### 生产用户安装
用户安装宿主（CGC 品牌下载页或 OpenClacky 官网），再经自托管 zip 一条命令安装本扩展：

```bash
openclacky ext install https://api.codingirlsclub.com/ext/cgc-2046.zip
```

扩展不在公共 Extension Marketplace 发布（2026-09-09 决议反转，见 `docs/plans/cgc-2046-openclacky-extension-refactor.md` R1）。zip 与版本元信息（`/ext/cgc-2046.json`）由 deploy CI 在 docker build 前经 `bin/pack` 生成，放 `backend/priv/static/ext/`（gitignored），Plug.Static 直接服务。

`bin/pack` 仅用于开发和发布前验收，会把本目录 symlink 到 `~/.clacky/ext/local/cgc-2046`（openclacky 开发层），因此开发期改完文件即生效（handler 按请求热加载），无需重复打包。

**版本纪律（同版本号 ≠ 同一份产物）**：分发清单的 `version` 取 `ext.yml`，用户在面板上能否看到「升级」按钮完全取决于这个号——**分发包内容一变就必须 bump** `ext.yml` 的 `version`，并把 `CHANGELOG.md` 的 `[Unreleased]` 段落改挂到该版本号下。否则已装用户的版本号与自己相同，面板判定「版本一致」，按钮永不出现，他们静默停在旧构建（2026-09-10 线上 0.1.1 即如此：已装 0.1.1 的用户拿不到当日合入的 plan 020–023）。

```bash
# 发版前自查：比较「线上已发布产物」与「本地待发布产物」的内容指纹
openclacky-ext/cgc-2046/bin/check-version-bump
# 内容变了但版本没动 → 非零退出并打印修法；线上不可达/清单畸形 → 警告放行
```

deploy CI 在构建扩展产物后调用同一脚本，失败即中止部署（见 `.github/workflows/deploy.yml` 的 Enforce extension version bump on content change）。指纹按 zip 内**逐条目 sha256 + 路径聚合**计算，与 zip 字节无关：zip 含条目 mtime，重建同一份内容字节也会变，拿 zip sha256 当"内容是否变化"的判据会把纯 backend 部署误判成内容变更。新增 `bin/` 下的脚本记得 `git add -f`（`bin/` 被本目录 `.gitignore` 排除）。

## 配置点

- `ext.yml` 顶层 `config.mcp_url`：MCP server 地址，默认生产值 `https://api.codingirlsclub.com/mcp`；本地联调优先用 connect 端点 body 的 `url` 字段覆盖（如 `http://localhost:4000/mcp`），全包唯一改 URL 的点。
- `ext.yml` 顶层 `config.web_url`：CGC-2046 网站前端地址，默认生产值 `https://codingirlsclub.com`；面板「打开 CGC-2046 网站」用它，`status` 响应透传（未配置则面板隐藏该链接）；本地联调改本地副本（如 `http://localhost:3000`）。scheme 门（`CgcKit.safeWebUrl`）只放行 https 或 loopback http（`localhost`/`127.0.0.1`/`[::1]`）——其它值（含 `javascript:` 等危险 scheme、LAN IP http）一律按未配置处理：链接隐藏、深链不渲染、详情标题退化纯文本。
- connect 端点 body 也接受 `url` 字段临时覆盖。

## 安全约定（真实边界）

- token 的目标落盘点只有 `~/.clacky/mcp.json`（connect 写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）；handler 的响应体、日志、data_path 文件一律不含 token。
- onboarding 主流程走「面板一键连接」或「剪贴板 → stdin 管道」：token 经管道传递，不出现在 argv、对话消息或工具参数里，因此不进入 OpenClacky 会话记录文件；`JSON.generate` 负责转义，剪贴板内容含引号/换行也安全。
- 无剪贴板 CLI 的环境首选备选 A（用户亲手把 token 写入 0600 临时文件、agent 管道读取、成功后删除）；对话粘贴是最后手段（备选 B），token 会留在会话记录中——skill 会明示代价并建议撤销后改走无留痕通道重签。
- MCP 工具结果（如 `invitation_token` 明文）会被客户端运行时记入会话记录，这是既定事实；我们的纪律是不主动把凭证写进额外文件/日志。
- status 端点只返回 `configured` / `url` / `token_configured`（布尔）/ `web_url`，永不返回 headers 或 token；面板与 handler 均不渲染 token。
- 所有扩展路由要求请求 `Host` 头为 loopback（`127.0.0.0/8`、`localhost`、`[::1]`，防 DNS rebinding 绕过 Origin 校验）；缺失或非 loopback 一律 403 `host not allowed`。
- 导航类外链（`web_url` 及其拼出的深链、`checkout_url`）统一过共享骨架 `CgcKit.safeWebUrl` scheme 门：https 任意 host，http 仅 loopback，其余一律 `null`；非法 ≡ 未配置（隐藏入口/退化纯文本，不建新 UI 态）。`web_url` 来自 ext.yml config（作者可控、随包分发），本地副本可能被篡改——门是纵深防御，不是对分发包的不信任。拼进 HTML 属性的 URL 一律 `escapeHtml`（含引号的 https 也无法属性逃逸）。
- connect 的条目名写死 `cgc-2046`，不会改动 mcp.json 里的其它 server 条目；更新时保留该条目上的未知额外键；`DELETE /connect` 只移除 `cgc-2046` 条目。

## Known limitations

- **宿主其它写路径不在本包控制面**：OpenClacky WebUI 的 `/api/mcp` 管理端点与本扩展可能并发写同一 `mcp.json`。本包内已用类级互斥锁 + 原子写加固自身路径，但无法锁住宿主写路径；根本解是在 OpenClacky 侧提供统一写 API（如 `Registry#upsert_server`），属上游改进建议。
- 卸载不自动清理 mcp.json 的 `cgc-2046` 条目（无 uninstall CLI）。

## 测试

需在项目 mise 环境（Ruby 4.x，系统 ruby 2.6 无 openclacky gem）。test/ 与 bin/ 经本目录 `.gitignore` 排除、不进 ext pack 发布包（packager 严格遵守容器 .gitignore），仅随 repo 供开发与验收运行：

```bash
cd openclacky-ext/cgc-2046
mise exec -- ruby test/mcp_config_test.rb        # mcp.json merge / 原子写 / 权限（test-first 交付）
mise exec -- ruby test/handler_routes_test.rb    # 请求级：422/200/回滚/500/501 + 无 token 泄漏（不落盘）
mise exec -- ruby test/offering_routes_test.rb   # 发现路由透传/503·502·500 分层 + 面板与 prompt 静态断言
mise exec -- ruby test/learner_journey_routes_test.rb # Learner 五路由/400·503·502·500 + 面板 v2 静态断言
mise exec -- ruby test/video_pipeline_assets_test.rb # 视频物料契约（模板/自检/素材/key 安全）+ skill 形态消失

# 或全量
for f in test/*.rb; do mise exec -- ruby "$f"; done
```

## 验证步骤（安装后自测）

1. `openclacky ext install openclacky-ext/dist/cgc-2046.zip`，确认 `openclacky ext list` 出现 `cgc-2046`。
2. 预置一个含其它 server 条目的 `~/.clacky/mcp.json`，走一遍 README 的连接流程；完成后检查：其它条目语义无损、`cgc-2046` 条目四键正确、文件权限 0600（重写时收紧既有宽松 mode）。
3. `GET /api/ext/cgc-2046/status` 返回 `configured:true` 且响应无 headers/token；`token_configured:true`、`web_url` 正确。
4. 在 agent 会话调 `list_my_workspaces` 选择工作台，再调 `get_role_playbook`；确认 agent 展示返回的 `version` 后才开始业务操作。
5. OpenClacky 侧边栏出现「CGC-2046」入口，打开面板显示已连接 + token 已配置；点「断开连接」确认后 `status` 变 `configured:false`，其它 server 条目无损。
