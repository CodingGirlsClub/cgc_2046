# CGC-2046 连接器扩展（cgc-2046）

OpenClacky 扩展：把 CGC-2046 工作台接入本机 agent。安装后提供：

- **API 端点**：`POST /api/ext/cgc-2046/connect` 把 token + MCP URL 原子化 read-merge-write 进 `~/.clacky/mcp.json`（新建 0600，类级互斥锁防并发，reload 失败自动回滚）并热重载 MCP registry；`GET /api/ext/cgc-2046/status` 查询配置状态（`configured` / `url` / `token_configured` / `web_url`，不泄漏 token）；`DELETE /api/ext/cgc-2046/connect` 断开连接（移除 `cgc-2046` 条目 + reload，同样原子写与回滚加固）；`POST /api/ext/cgc-2046/skills/sync` 为后续切片留位（当前返回 501）。全部路由做 Origin/Host 同源校验（无 Origin 的本地 curl 放行）；写路由（POST 及 `DELETE /connect`——同为写端点，跨站可借宿主全开的 preflight 发出 cross-site DELETE）另需 `Content-Type: application/json` + `X-CGC-CSRF-Token`（进程级 token 经 `GET /status` 同源下发，防跨站伪造写——尤其 connect 可改写 mcp.json 指向）；`GET /api/ext/cgc-2046/offerings` 与 `GET /api/ext/cgc-2046/offerings/:id` 透传公开浏览工具（`list_public_offerings` / `get_public_offering`，membership: public，无需 workspace_id），供发现面板使用。
- **panel**：`cgc-2046`——侧边栏入口打开连接状态面板（configured / url / token 配置状态 + 断开连接 + 跳转网站）；`cgc-2046-course`——课程学习面板（我的课程 / 学习目标地图 / 草稿编辑 / 待复习队列）；`cgc-2046-discovery`——发现面板（公开活动/课程列表，标题/时间/地点/状态标签，条目跳 web 详情页；未连接显示连接引导）。
- **agent**：`cgc-assistant`——通过 CGC MCP 工具读写工作台的助手（17 个工具，含 two-tool 确认流与公开浏览豁免）。
- **skill**：`cgc2046-onboarding`——引导创建 token、经剪贴板管道调 connect、验证状态的连接流程。
- **hooks**（OpenClacky ≥1.5.7 事件能力）：
  - `after_tool_use`——主 agent 每次调用 CGC MCP server（virtual skill `mcp:cgc-2046`，条目名与扩展 id 统一）后推 `ext.cgc-2046.tool_used` 事件（成功 persist: true 进消息流，失败仅实时提示）；subagent 内 curl 连接失败不抛异常、错误文本藏在 subagent summary 里——文本特征命中（MCP server 'cgc 前缀 / Connection refused / Failed to open TCP / localhost:4102 等具体形态）时另推 `ext.cgc-2046.mcp_error`（错误片段截断 + 抹凭证，覆盖 Bearer / cgc_ 前缀 / 裸 JWT 形态）。
  - `on_tool_error`——防御性：工具调用真正抛异常且错误与 CGC MCP 连接相关时推 `ext.cgc-2046.mcp_error`（当前 agent 侧 MCP 走 virtual skill + curl 路径，一般不触发）。
- **面板事件订阅**：面板「最近活动」区实时展示上述两个事件。

要求 **openclacky >= 1.3.7**（api handler / ext pack / install 能力自 v1.3.7 引入）。

## 目录结构

```
openclacky-ext/cgc-2046/
  ext.yml                          # manifest（id 与目录名一致；config.mcp_url 是唯一改 URL 的点）
  api/
    handler.rb                     # 薄 DSL 层：路由 + 上下文 + error! 惯例 + origin/CSRF 收口
    mcp_config.rb                  # mcp.json read-merge-write 纯逻辑（不依赖 clacky gem，含原子写）
    course_routes.rb               # 课程数据面 + 共享 call_tool 管道（503/502/500 分层，409 冲突映射）
    offering_routes.rb             # 发现面板公开浏览数据面（复用 course_routes 管道）
    workbench_routes.rb            # 工作台身份数据面（workspaces/playbook/tasks）
    learner_routes.rb              # Learner 发现/报名/支付数据面（S7）
  panels/
    workspace/view.js              # 侧边栏入口 + 连接状态面板（身份区/任务/断开连接）
    cgc-course/view.js             # 课程学习面板（列表/详情/草稿编辑/轮询）
    cgc-discovery/view.js          # 发现面板 v2（合并流 + 报名确认卡 + 支付轮询）
  agents/cgc-assistant/
    system_prompt.md               # CGC-2046 助手人设与工具说明
  skills/cgc2046-onboarding/
    SKILL.md                       # 连接引导流程（剪贴板管道主流程）
  hooks/
    after_tool_use.rb              # CGC MCP 调用后推 tool_used / mcp_error 事件
    on_tool_error.rb               # 工具异常文本命中 CGC 形态时推 mcp_error 事件
    credential.rb                  # 两 hook 共享的凭证脱敏正则
  bin/pack                         # 打包脚本（symlink → ext pack → ext verify）
  test/
    mcp_config_test.rb             # 纯逻辑单测（minitest，stdlib）
    handler_routes_test.rb         # 请求级测试（fake req + Halt 捕获，不落盘）
    offering_routes_test.rb        # 发现路由 + 面板/prompt 静态断言（FakeRegistry + allocate 先例）
    course_routes_test.rb          # 课程路由（call_tool 管道与错误分层）
    course_content_write_test.rb   # 草稿写路径（协议错误/409 冲突）
    workbench_routes_test.rb       # 工作台路由
    hooks_test.rb                  # 生命周期钩子
    learner_journey_routes_test.rb # Learner 路由 + guard 收口 + 面板静态断言（S7）
    panel_behavior_harness.js      # 面板行为级 harness（node 驱动 view.js，DOM 断言）
```

## 打包与安装

```bash
# 打包（产物在 openclacky-ext/dist/，已 gitignore）
openclacky-ext/cgc-2046/bin/pack

# 安装
openclacky ext install openclacky-ext/dist/cgc-2046.zip
```

`bin/pack` 会把本目录 symlink 到 `~/.clacky/ext/local/cgc-2046`（openclacky 开发层），因此开发期改完文件即生效（handler 按请求热加载），无需重复打包。

## 使用流程

1. 在 CGC-2046 网站工作台的「MCP」页 `/w/<slug>/settings/integrations/agents/mcp` 创建 token 并**复制到剪贴板**（明文只显示一次；不要粘贴进对话）。
2. 在 OpenClacky 里新建会话、选择 `cgc-assistant`（或任意带 terminal 的会话触发 `cgc2046-onboarding` skill）。
3. skill 用「剪贴板 → stdin 管道」命令写入配置（loopback 免 access-key；token 不进 argv、不进入会话记录）。connect 是写端点，需 CSRF token：命令先 `GET /status`（无 Origin 的本地 curl 放行）取 `csrf_token`，再以 `-H "X-CGC-CSRF-Token: $CGC_CSRF"` POST `/connect`——完整命令见 `skills/cgc2046-onboarding/SKILL.md`。
4. `GET /api/ext/cgc-2046/status` 返回 `configured:true` 后即可提问工作台问题。
5. 侧边栏「CGC-2046」入口可随时查看连接状态；「断开连接」移除 `cgc-2046` 条目（`DELETE /api/ext/cgc-2046/connect`），不触碰其它 server 条目。

## 配置点

- `ext.yml` 顶层 `config.mcp_url`：MCP server 地址，默认生产值 `https://api.codingirlsclub.com/mcp`；本地联调优先用 connect 端点 body 的 `url` 字段覆盖（如 `http://localhost:4000/mcp`），全包唯一改 URL 的点。
- `ext.yml` 顶层 `config.web_url`：CGC-2046 网站前端地址，默认生产值 `https://codingirlsclub.com`；面板「打开 CGC-2046 网站」用它，`status` 响应透传（未配置则面板隐藏该链接）；本地联调改本地副本。
- connect 端点 body 也接受 `url` 字段临时覆盖。

## 卸载

无 CLI 子命令（known limitation），手动两步：

```bash
rm -rf ~/.clacky/ext/installed/cgc-2046
# 断开连接（移除 cgc-2046 条目）：面板「断开连接」按钮，或本地 curl
# （DELETE 为写端点：Content-Type + CSRF token，token 先经 /status 取，无 Origin 本地 curl 放行 origin 校验）
CGC_CSRF=$(curl -sS "http://127.0.0.1:7070/api/ext/cgc-2046/status" | ruby -rjson -e 'print (JSON.parse(STDIN.read)["csrf_token"] rescue "")') && \
curl -sS -X DELETE "http://127.0.0.1:7070/api/ext/cgc-2046/connect" -H "Content-Type: application/json" -H "X-CGC-CSRF-Token: $CGC_CSRF"
# 或手动编辑 ~/.clacky/mcp.json，删除 mcpServers 下的 "cgc-2046" 条目
```

`~/.clacky/ext-data/cgc-2046/`（若存在）默认保留。

## 安全约定（真实边界）

- token 的目标落盘点只有 `~/.clacky/mcp.json`（connect 写入期间存在短暂的 0600 临时文件，原子 rename 后即清除）；handler 的响应体、日志、data_path 文件一律不含 token。
- onboarding 主流程走「剪贴板 → stdin 管道」：token 经管道传递，不出现在 argv、对话消息或工具参数里，因此不进入 OpenClacky 会话记录文件；`JSON.generate` 负责转义，剪贴板内容含引号/换行也安全。
- 无剪贴板 CLI 的环境首选备选 A（用户亲手把 token 写入 0600 临时文件、agent 管道读取、成功后删除）；对话粘贴是最后手段（备选 B），token 会留在会话记录中——skill 会明示代价并建议撤销后改走无留痕通道重签。
- MCP 工具结果（如 `invitation_token` 明文）会被客户端运行时记入会话记录，这是既定事实；我们的纪律是不主动把凭证写进额外文件/日志。
- status 端点只返回 `configured` / `url` / `token_configured`（布尔）/ `web_url`，永不返回 headers 或 token；面板与 handler 均不渲染 token。
- connect 的条目名写死 `cgc-2046`，不会改动 mcp.json 里的其它 server 条目；更新时保留该条目上的未知额外键；`DELETE /connect` 只移除 `cgc-2046` 条目。

## Known limitations

- **宿主其它写路径不在本包控制面**：OpenClacky WebUI 的 `/api/mcp` 管理端点与本扩展可能并发写同一 `mcp.json`。本包内已用类级互斥锁 + 原子写加固自身路径，但无法锁住宿主写路径；根本解是在 OpenClacky 侧提供统一写 API（如 `Registry#upsert_server`），属上游改进建议。
- 卸载不自动清理 mcp.json 的 `cgc-2046` 条目（无 uninstall CLI）。

## 测试

需在项目 mise 环境（Ruby 4.x，系统 ruby 2.6 无 openclacky gem）：

```bash
cd openclacky-ext/cgc-2046
mise exec -- ruby test/mcp_config_test.rb        # mcp.json merge / 原子写 / 权限（test-first 交付）
mise exec -- ruby test/handler_routes_test.rb    # 请求级：422/200/回滚/500/501 + 无 token 泄漏（不落盘）
mise exec -- ruby test/offering_routes_test.rb   # 发现路由透传/503·502·500 分层 + 面板与 prompt 静态断言
mise exec -- ruby test/learner_journey_routes_test.rb # Learner 五路由/400·503·502·500 + 面板 v2 静态断言

# 或全量（8 文件）
for f in test/*.rb; do mise exec -- ruby "$f"; done
```

## 验证步骤（安装后自测）

1. `openclacky ext install openclacky-ext/dist/cgc-2046.zip`，确认 `openclacky ext list` 出现 `cgc-2046`。
2. 预置一个含其它 server 条目的 `~/.clacky/mcp.json`，走一遍「使用流程」；完成后检查：其它条目语义无损、`cgc-2046` 条目四键正确、文件权限 0600（既有文件 mode 不变）。
3. `GET /api/ext/cgc-2046/status` 返回 `configured:true` 且响应无 headers/token；`token_configured:true`、`web_url` 正确。
4. 在 agent 会话调 `get_workspace_context` 成功返回工作台信息。
5. OpenClacky 侧边栏出现「CGC-2046」入口，打开面板显示已连接 + token 已配置；点「断开连接」确认后 `status` 变 `configured:false`，其它 server 条目无损。
