---
title: "CGC-2046 OpenClacky 扩展与 MCP 首次接入重构计划"
status: proposed
artifact_readiness: requirements-only
created: 2026-09-06
scope: "cgc-2046 branded extension, website onboarding, MCP pairing and connection health"
---

# CGC-2046 OpenClacky 扩展与 MCP 首次接入重构计划

## 1. 目标与问题边界

CGC-2046（`cgc-2046`）已经发布到 CGC 自己控制的品牌交付链路。本计划把“用户登录 CGC 后使用 OpenClacky”的首次接入从多次跨应用手工操作，重构为可验证、可恢复的连接流程：用户通过 CGC OpenClacky 提供的一键安装链接安装一个已内置 `cgc-2046` 的宿主包，之后由网站与内置扩展完成身份配对、MCP 配置和连接验证。

本计划覆盖：

- CGC OpenClacky 一键安装包中内置扩展的打包、版本与发布元数据；
- CGC 网站的安装引导、连接入口、状态显示和失败恢复；
- 扩展面板与 API 的配对流程、`mcp.json` 写入和 MCP 健康检查；
- 既有手工 token/剪贴板流程的兼容回退；
- 发布、升级、卸载、撤销和安全审计要求。

本计划不覆盖：

- 重写 CGC MCP 领域工具、RBAC、工作区作用域或业务数据模型；
- 在 CGC 服务端运行 LLM/Agent；
- 修改用户当前未提交的本地工作区变更；
- 让网站直接读取或写入用户本机文件系统。

## 2. 当前基线与证据

### 2.1 扩展基线

- `openclacky-ext/cgc-2046/ext.yml` 已声明 `api`、多个 `panels`、三个 `agents`、两个 `skills` 和 hooks，说明它是完整扩展容器，不是单一 Skill。
- `openclacky-ext/cgc-2046/bin/pack` 当前面向本地开发：建立 `~/.clacky/ext/local/cgc-2046` symlink，运行 `openclacky ext pack` 与 `openclacky ext verify`。
- `openclacky-ext/cgc-2046/api/handler.rb` 已提供 `connect`、`status`、`disconnect` 等本机 API；写入逻辑委托给 `Cgc2046McpConfig`，具备原子写、0600 权限、互斥和 reload 失败回滚。
- `openclacky-ext/cgc-2046/README.md` 仍把本地 zip 安装和手工 token 流程作为主文档，需改成 CGC OpenClacky 一键安装为主、手工流程为回退。

### 2.2 网站基线

- `web/components/agent-connect-sections.tsx` 将 OpenClacky 安装、扩展安装和 token 生成拆成三张内容卡；扩展卡当前直接提示用户在市场搜索 `CGC-2046`，需改成说明扩展已随 CGC OpenClacky 内置。
- `web/components/onboarding-wizard.tsx` 的完成判定是 token 签发后用户点击“我已保存”；这不等于扩展已安装、`mcp.json` 已写入或 MCP 已握手。
- `web/app/[locale]/w/[slug]/settings/integrations/agents/mcp/page.tsx` 是 token 管理页，当前承担首次签发和后续撤销两类职责。
- `web/lib/mcp.ts` 与 `backend` 的 MCP token 契约已经区分登录 token 与连接 token；该安全边界应保留。

### 2.3 OpenClacky 官方约束与 CGC 交付边界

- OpenClacky 的扩展容器支持同时包含 `api`、`agents`、`panels`、`skills` 的完整扩展；本阶段不把它发布到公共 Extension Marketplace。
- `ext.yml` 是扩展贡献的声明入口；`clacky ext verify` 是 CGC OpenClacky 打包和发布前的基础校验。
- panel 与宿主同源，可读取宿主公开 API（例如 MCP 配置状态）；安装/禁用扩展和全局授权仍属于宿主控制面。
- 扩展 hook 是任意 Ruby 代码，交付说明和安装确认页必须说明其事件、权限和副作用。

## 3. 目标用户旅程

### 3.1 默认路径

```text
CGC 登录
  → 点击“连接 OpenClacky”
  → 点击 CGC OpenClacky 一键安装链接
  → 安装并打开已内置 cgc-2046 的 OpenClacky
  → 打开 CGC 面板并点击“连接 CGC”
  → 浏览器完成 CGC 登录确认
  → 扩展取得一次性配对结果
  → 原子写入 ~/.clacky/mcp.json
  → initialize + tools/list 健康检查
  → 网站与扩展均显示“已连接”
```

### 3.2 回退路径

当宿主版本不支持配对、浏览器未登录、扩展 API 不可用或健康检查失败时，用户可以进入“手动连接”路径：网站一次性显示 token，扩展 onboarding skill 通过剪贴板 → stdin 管道调用本地 `connect` API。token 不进入 URL、对话消息、命令参数、日志或额外文件。

## 4. 目标状态与需求

### R1. CGC OpenClacky 一键安装与内置扩展事实

- CGC OpenClacky 提供一个面向新用户的一键安装链接；用户不需要单独搜索、下载或安装 `cgc-2046` 扩展。
- 安装包/安装器必须把兼容版本的 OpenClacky 与 `cgc-2046` 一起交付，并在安装后把扩展放入宿主可加载的位置。
- 发布包必须通过 `openclacky ext verify`，并在 CI 中验证 manifest 引用的每个文件存在且可加载。
- CGC OpenClacky 的版本、内置扩展版本、安装 artifact 和下载链接必须有单一来源；升级时必须明确宿主与扩展的兼容矩阵。
- 公共 Extension Marketplace 发布明确不属于本阶段；未来若重新打开，另起发布计划。

### R2. 网站连接入口

- 网站主 CTA 从“生成 token”升级为“连接 OpenClacky”。
- 页面按真实状态显示：未安装、已安装未连接、配对中、已连接、连接失败、凭证已撤销。
- “token 已签发”不能单独触发 onboarding 完成；完成必须依赖扩展回报配置成功和 MCP 健康检查成功。
- token 管理页保留撤销、重连和设备命名能力，但不再承担默认首次接入流程。

### R3. 一次性安全配对

- 扩展发起配对时生成不可预测 nonce，并在本机短期保存；nonce 不进入 agent session、日志或 URL 查询参数。
- 网站登录后把配对请求绑定到当前用户；配对码短时有效、单次消费、不可跨用户或跨工作区复用。
- 后端只向已确认的扩展实例返回一次性连接结果；不得把长期 token 暴露给网页脚本以外的第三方来源。
- 配对失败、超时、重复消费和用户取消都返回可诊断但不泄漏凭证的错误码。

### R4. 自动 MCP 配置与健康检查

- 扩展使用已有 `Cgc2046McpConfig` 事务边界，把 `mcpServers["cgc-2046"]` 原子化 read-merge-write 到 `~/.clacky/mcp.json`，保留其他 server 和未知字段。
- 写入成功后热加载 MCP registry；reload 失败必须回滚到进入前字节内容。
- 扩展在完成写入后执行真实 MCP `initialize`、`initialized` 和 `tools/list` 检查；只读健康检查不得产生业务写入或审计副作用。
- 健康检查结果返回结构化状态（配置存在、URL、握手成功、工具数/版本），永不返回 Authorization header 或 token。

### R5. 状态闭环与恢复

- 扩展面板能从宿主 API 和本地 extension API 读取连接状态，并提供重新配对、测试连接、断开连接和打开网站入口。
- 网站在获得扩展回调或下一次刷新后能看到真实连接状态；状态更新不能依赖用户整页刷新才能出现。
- MCP token 90 天未使用失效、手动撤销和每用户 active 上限等既有契约保持不变。
- 断开连接只删除 `cgc-2046` 条目，不影响其他 MCP server；卸载扩展时必须明确告知是否保留连接配置。

### R6. 手工回退与兼容

- `cgc2046-onboarding` 继续支持旧版宿主、无法打开配对页面和诊断场景。
- 剪贴板主流程保持 token 不进 argv、会话参数、日志和额外文件；无剪贴板环境继续支持短期 0600 临时文件回退。
- 网站只在自动配对不可用时展示手工 token 指引，并说明凭证只显示一次和撤销方式。

## 5. 计划实施单元

### U1. CGC OpenClacky 安装包与内置扩展交付收敛

**涉及文件：** `openclacky-ext/cgc-2046/ext.yml`、`openclacky-ext/cgc-2046/bin/pack`、`openclacky-ext/cgc-2046/README.md`、CGC OpenClacky/安装器发布配置（具体路径在实施前确认）。

**工作内容：**定义 CGC OpenClacky 一键安装 artifact 的组成、下载链接、checksum、版本和最低宿主版本；打包时把 `cgc-2046` 放入宿主可加载目录；把 README 和网站引导改成“一键安装 CGC OpenClacky，扩展已内置”。

**验证：**全新机器只使用 CGC 提供的链接即可安装；启动后 `cgc-2046` 已加载；`ext verify` 通过；升级到下一版本不丢失 `mcp.json` 中其他条目；不需要访问公共 Extension Marketplace。

### U2. Pairing 状态机与服务端契约

**涉及文件：** 后端 MCP/token 领域与 GraphQL/HTTP 边界（实施前用 `mainline context --files` 冻结确切文件）；网站连接状态类型与客户端 API。

**工作内容：**定义 pairing request、短时 nonce、用户确认、单次消费、过期、取消和结果回调的状态机；把长期连接 token 只交给已确认扩展；错误码不泄漏用户或 token 存在性。

**验证：**正常配对、过期、重复消费、跨用户、取消、并发确认、后端重启和扩展重试场景；确认长期 token 不出现在 URL、日志、GraphQL 普通查询或 session 内容。

### U3. 扩展连接控制面

**涉及文件：** `openclacky-ext/cgc-2046/api/handler.rb`、`openclacky-ext/cgc-2046/api/mcp_config.rb`、新增 pairing/health route 与测试。

**工作内容：**增加配对启动/轮询或回调、health check、版本/宿主能力报告；复用现有 Origin/CSRF、互斥、原子写和回滚；将 connect API 的 token 直传作为兼容入口而非默认入口。

**验证：**成功写入、既有配置 merge、reload 失败回滚、并发写、错误响应脱敏、健康检查失败、断开连接和宿主 MCP registry 热加载。

### U4. 扩展 hub 与状态 UI

**涉及文件：** `openclacky-ext/cgc-2046/panels/cgc-home/view.js`、相关 panel 测试与 `ext.yml` panel 声明。

**工作内容：**加入“连接 CGC”主按钮、配对中进度、已连接详情、测试连接、断开/重新配对和失败恢复；状态文案区分“扩展已安装”和“平台已连接”。

**验证：**未配置、配对中、成功、token 失效、服务不可达、断开后重连、已有其他 MCP server 等状态；禁止渲染 token/header。

### U5. 网站 onboarding 重构

**涉及文件：** `web/components/onboarding-wizard.tsx`、`web/components/agent-connect-sections.tsx`、`web/app/[locale]/w/[slug]/settings/integrations/agents/mcp/page.tsx`、相关 translations/tests。

**工作内容：**把默认流程改为安装扩展 → 打开连接 → 等待真实 health check；保留手工 token fallback；用连接状态而不是“我已保存”驱动完成态；增加可恢复错误和状态刷新/回调机制。

**验证：**网站首次接入、扩展已安装、扩展未安装、自动配对失败、手工回退、token 撤销、跨工作区切换、浏览器返回/重复点击、页面重新进入后状态恢复。

### U6. 发布后运维与安全验证

**涉及文件：** `openclacky-ext/cgc-2046/test/`、web/backend 专项测试、发布文档和运行手册。

**工作内容：**建立发布 smoke test、版本回滚、卸载保留策略、MCP server URL 变更策略、宿主最低版本策略和凭证泄漏扫描。

**验证：**真实 OpenClacky 实例安装 → 配对 → MCP handshake → 调用只读工具；失败路径验证不会破坏用户其他 MCP 配置；发布 artifact checksum 与 CGC OpenClacky 版本和内置扩展版本一致。

## 6. 依赖与顺序

1. 先确认 CGC OpenClacky 一键安装链路、安装 artifact、下载域名、checksum、宿主安装方式，以及 OpenClacky 对 bundled/local extension 的加载规则。
2. U1 与 U2 并行设计，但 U3 依赖 U2 的 pairing 契约。
3. U3 完成后才能实现 U4/U5 的真实状态闭环；UI 不能先用“token 已生成”伪造连接成功。
4. U6 必须在 CGC OpenClacky 对外更新前完成，至少覆盖一个全新本机实例和一个已有其他 MCP server 的升级实例。

## 7. 关键决策与理由

- **默认采用一次性配对，不把长期 token 放入 URL 或对话。** 这是降低复制错误和凭证泄漏风险的最小方案。
- **继续以 `~/.clacky/mcp.json` 作为 MCP 配置单一落点。** 现有事务实现已经覆盖原子写、权限和回滚；重构连接入口，不重复造配置存储。
- **保留手工 token 作为 fallback。** 它服务于旧宿主和异常环境，但不应继续作为 happy path。
- **网站和扩展都显示连接状态，后端 MCP 仍是权限真源。** 前端状态只表达连接性，不复制 RBAC 或工作区授权语义。
- **不把完整扩展拆成多个独立 Skill。** panel/API/hooks/agents 是产品闭环的一部分；独立 Skill 仅在确有复用价值时单独发布。

## 8. 风险与未决问题

- **安装交付状态：** 需确认 CGC OpenClacky 当前一键安装链接、artifact 形态、内置扩展落盘位置、已安装用户的升级策略和回滚方式。
- **配对回传能力：** 需确认 OpenClacky 是否支持稳定的 deep link、loopback callback 或扩展轮询；在确认前不能锁定具体传输方式。
- **宿主并发写：** OpenClacky WebUI 的 MCP 管理端点可能与扩展同时写 `mcp.json`；长期解决方向是宿主统一提供 upsert API。
- **工作区选择：** MCP token 绑用户不绑工作区；配对默认只确认账号，工作区仍由 Agent/业务工具按既有作用域规则确定。
- **版本漂移：** 用户可能安装旧扩展或旧宿主；必须在扩展面板中报告能力版本并提供手工 fallback。

## 9. 完成标准

- 新用户通过 CGC OpenClacky 提供的一键安装链接即可获得 OpenClacky 与内置 `cgc-2046`，不需要单独安装扩展、访问公共 Marketplace、本地 zip 或终端命令。
- 自动配对成功后，用户无需复制 token、粘贴配置或向 Agent 发送凭证。
- 扩展自动写入并热加载 `mcp.json`，完成真实 MCP 握手和工具列表检查。
- 网站、扩展和 MCP 管理页对“已安装”“已配置”“已握手”“已授权”有一致且可恢复的状态表达。
- 手工回退仍安全可用，且所有失败路径都不会泄漏 token、破坏其他 MCP server 或把失败误报成成功。
- 发布 artifact、CGC OpenClacky 版本、manifest、安装/升级/卸载文档和 smoke test 可追溯到同一个版本。
