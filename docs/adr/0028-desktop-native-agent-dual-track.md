---
status: accepted
date: 2026-10-22
accepted: 2026-10-25
---

# ADR-0028：桌面客户端内建 Rust native agent，与 external agent 双轨并存

> 日期：2026-10-22 ｜ 状态：**已接受（Accepted，2026-10-25 产品确认；决策 2/3/6/11 同日修订）** ｜ 决策者：用户（product owner）
> 关联：ADR-0001（BYO）、ADR-0003（pi 设计哲学）、ADR-0022/0023（本机 Host 与多 agent）、ADR-0024（技术栈）、ADR-0025（桌面内化 Host）、ADR-0026（注册表）、ADR-0027（分发）；架构脊柱 `_bmad-output/initiative-desktop/architecture-desktop/architecture-desktop.md`（AD-4/AD-5/AD-15/AD-16/AD-17）

## 背景（Context）

桌面客户端目前是 ACP 客户端：`platform::acp` / `platform::agent` 经 stdio 驱动学员自装的外部 agent（OMP / Codex / Claude Code），模型额度、审批习惯、登录都留在外部 agent 里（ADR-0022 / ADR-0023 / ADR-0025）。架构脊柱 AD-4 因此明确写「不实现 native agent、LLM 客户端与工具沙箱」。

这条路径有三个产品缺口：

1. **小白不可用**：学员要先装 agent、自己准备模型 key 或订阅。对第一次接触 agent 的用户门槛过高，也没有可售卖的模型额度。
2. **体验不可控**：教学 prompt、工具、审批、错误文案都受外部 agent 版本与行为影响。ADR-0023 已记录适配器默认审批模式、guardian review 撞额度、SIGKILL 留孤儿等真实问题。
3. **多 mate 难扩展**：学习搭子之外的教研 mate、event mate 若继续走外部适配器，每类 agent 都要新增适配与回归成本。

Zed 的实践提供了直接参照：native agent 是进程内 Rust 实现，与 external agent 共用一套 `AgentServer → AgentConnection` 抽象与 UI；Provider 层是「纯数据 Model + Provider trait」，settings 驱动自定义 OpenAI-compatible provider，凭据进 keychain。CGC 在 2026-10-22 对话中确认：web 端 agent 冻结、后续退役；桌面端采用 native，external agent 保留；v1 不做订阅 OAuth；CGC 网关作为小白默认 Provider。

## 决策（Decision）

1. **双轨并存**：桌面端内建第一方 **native agent**（Rust，进程内）作为默认学习 agent；现有 **external agent**（ACP）路径保留为高级模式。与 Zed 同构：一个 UI 契约，两个实现。web 端 agent 冻结，只修安全问题，后续单独决定退役时间；`cgc-host` 不新增功能。
2. **统一边界（2026-10-25 修订）**：双轨的收敛点不是"两个 Host 实现同一事件契约"，而是 Zed 形状的
   **一个客户端会话模型 + 一套 UI**：两轨各自把数据喂进同一个会话模型（ACP 由协议通知归约，
   native 由进程内事件直接归约），UI 只读模型；agent 差异通过 `AgentConnection` 式能力位表达，
   不做 agent 类型分支。Stage 0 已先落地行为层（消息操作栏/复制/滚动判定共用
   `message_flow`），Stage 1 把共享渲染/composer 收进 `agent_ui`，Stage 2 引入统一会话模型。
   原方案中的 `NativeHost`（模拟同一 `HostEvent` 接口）被否决：native 不需要假协议，直接复用
   模型与类型更薄。agent 选择器照 Zed 的「+」菜单：**最上面是 CGC Agent（native），分隔符之后是
   external agents，默认折叠**；native 为默认项。
3. **native agent 分层**（新增 crate，遵循 AD-1 与「出现第二个真实消费者再拆」；2026-10-25 与代码对齐）：
   - `agent_provider`：`LanguageModel`（纯数据）+ `Provider` trait（`stream_completion` 必填）+ 统一 Request / Event / TokenUsage / 错误分类 + 各 provider 适配；
   - `agent_core`：turn loop、会话状态机、取消、重试、compaction 挂点；
   - `agent_tools`：工具 trait、schema 规范化、审批决策、危险命令规则、沙箱；
   - `agent_host`：native 的 `AgentCommand`/`AgentEvent` 与 `HostState` 归约（UI 读它渲染）；
   - `agent_store`：本地会话持久化（SQLite）；
   - `agent_checkpoint`：Git checkpoint（临时索引 + 隐藏 ref）。
   MCP 客户端不新增 `agent_mcp` crate：放 `platform` 的 MCP 资产层，供 ACP 注入与 native 客户端
   共用（见决策 6，避免为单一消费者拆 crate）。
   UI 归 **`agent_ui`**（2026-10-25 由 `agent_chat` 改名，对齐 Zed）；`app` 只做组合根与窗口/路由聚合。
   Stage 1 先把共享消息流渲染/composer 搬进 `agent_ui`，Stage 2 再搬会话模型（会话模型暂同 crate，
   出现第二个消费者再裂出 model crate）。
4. **Provider 可配置**：照 Zed 的 `language_model_core` 四件套实现。首批：
   - 官方：**CGC 网关**（OpenAI 兼容，登录 token，订阅额度，小白默认）；
   - 国产 BYO：DeepSeek / 通义 / Kimi / GLM / 豆包 / 硅基流动（OpenAI 兼容 + 每模型 capability 覆盖）；
   - 海外 BYO：OpenAI / Anthropic / Google / OpenRouter；
   - 本地：Ollama / LM Studio；
   - 自定义：任意 OpenAI-compatible endpoint（含用户自己的中转站；CGC 不转售、不承担上游供给）。
   凭据：API key 存 keychain 且与 `api_url` 绑定；**CGC 网关用登录会话 token**，照 Zed Cloud 的鉴权模式：服务端签发短时 LLM token（Bearer），响应带 `expired/outdated` 信号或 401 时刷新并只重试一次；402 映射为「订阅/额度不足」，429 映射为限流，403 映射为重新登录。**v1 不做 ChatGPT / Claude 订阅 OAuth**；key 不进 settings 与日志，登出清理。
   模型目录：客户端内置可版本化 JSON（context / tools / vision / thinking / 价格可选）+ 远程增量覆盖 + 用户可手填自定义模型。用量：本地 `TokenUsage` 展示；网关模式服务端计量配额。
5. **工具与权限**：v1 工具为读文件、写 / 编辑、搜索、列目录、终端命令、课程与学习工具（经 MCP）、可选 web 搜索。审批沿用现有 permission 事件与卡片，危险命令内置规则。**OS 级沙箱（macOS Seatbelt / Linux bwrap / Windows WSL）在 P1 就要落地**，与终端工具同批交付；**沙箱不可用时（如 Windows 无 WSL）降级为逐条命令审批并显式提示风险**，不静默放行。参考 Zed 的实现路径但只取 approach（Zed 为 GPL-3.0-or-later，代码复用需人裁）。
6. **平台工具经 MCP 获取（2026-10-25 修订）**：MCP 是**客户端资产**——客户端持有唯一的 MCP
   配置/注册表（形状对齐 Zed 的 `context_servers`：Stdio `{command,args,env}` / Http
   `{url,headers,timeout}`），按 session 物化后由两个 runtime 消费：ACP 轨序列化成
   `mcp_servers` 注入 `session/new`/`load`；native 轨由客户端 MCP client 连上并注册工具。
   **v1 的配置来源是平台租赁**：`learning_host` lease 的 CGC MCP，只放行学习循环 5 个工具，
   session 级、不落盘、不写用户 `mcp.json`。**v1 不开放用户自定义 MCP server**；用户可编辑的
   `context_servers` 作为后续高级模式开口，届时须受 ADR-0026（签名清单/白名单，不自动装第三方）
   与 ADR-0021（服务端 scopes）约束。native MCP client 与「native 在课程页转默认」同批
   （P1b）交付，避免学员缺学习工具、双轨能力不等价。
7. **会话存储**：native 会话只存本机（SQLite），不上传平台、不进遥测与日志；**不做应用层加密，依赖系统账户隔离**（数据库 0600、位于用户数据目录）；用户可清除。AD-16 从「客户端不落对话」改为「对话只存本机、由 native agent 持有；外部 agent 仍由各自持有」。
8. **CGC 网关**：作为 native 的默认 Provider 与商业化路径；服务端计量与配额，复用现有支付与 Oban。平台自此提供模型服务，需同步修订 ADR-0001 的边界与隐私 / 合规口径。
9. **变更审阅与 Checkpoint（P1，Git）**：照 Zed 的做法，每条用户消息绑定一个 Git checkpoint：turn 开始时用临时索引做快照（`add --update` + 未跟踪文件，排除 ignore 与 >2 MB 文件），`write-tree` 后创建 commit 对象，写入隐藏 ref `refs/cgc/checkpoints/<thread>/<seq>`，不移动分支、不污染用户 index。Keep/Reject 走 `git diff` 与 `git restore --source`；Restore Checkpoint = 取消生成 → 截断会话 → `git restore --source <sha> --worktree .`，用户手改冲突时提示覆盖或跳过。每线程保留最近 50 个 ref，超限删 ref 并 `git gc --auto`；assistant 仓库上限 500 MB、课程仓库软上限 200 MB。**不建自建 blob 存储**——Git 已提供内容寻址、压缩、delta 与 GC。
10. **工作区与 Scope**：agent panel 全局可用（所有页面跟随 active tab），文件工作区按页面作用域解析：课程页用共享课程目录 `~/cgc2046_workspace/courses/<userId>/<courseId>`，其它页面用 `~/cgc2046_workspace/assistant/<userId>`（Windows 为 `%USERPROFILE%\...`）。native 与 external 共用这棵树（web Host 已于 2026-10-26、OMP 插件已于 2026-10-29 移除），会话按 canonical cwd 分桶；沙箱根 = 当前 scope 目录；页面上下文只提供受限元数据（route / tab / 选中实体 id），不塞整页数据。**线程按 scope 一条**（课程一条、助手一条），切换 scope 载入对应线程，同一 scope 内切页面不换线程；assistant 工作区上限 500 MB。桌面 ACP 现用的临时目录是偏差（AD-17 #1），native 起改用共享树并建议 ACP 同批切换。
11. **Git 是 checkpoint 前提，不是 native agent 硬前提（2026-10-25 修订）**：native agent 在无 Git
    环境下仍可用，但 Checkpoint / Keep / Reject / Restore 不可用，并给一次显式提示；onboarding 仍
    推荐安装 Git。每个 scope 目录默认初始化仓库（`.gitignore` + 初始 commit；已有 `.git` 则尊重
    用户仓库；无 remote、禁止 push；`.git` 沙箱只读；破坏性 git 命令需审批）。Checkpoint 直接使用
    Git（临时索引 + 隐藏 ref + `git restore --source`），不实现自建 blob 存储。
12. **迁移**：external 路径完全不动；native 在课程页按 workspace / 课程灰度开关接入；web 端 agent 冻结。

## 实现状态（2026-10-25）

- **已落地**：native agent 全链路（provider / turn loop / 工具+审批 / 事件归约 / SQLite / Git
  checkpoint）；双轨并存；消息操作栏/复制/滚动判定已收敛到共享 `message_flow`（Stage 0）；
  native 与 external 的 Backend 契约仍是两套（待 Stage 2 统一会话模型）。
- **已修订**：决策 2（去掉 `NativeHost` 假协议方案，改为共享客户端会话模型）、决策 3（与代码
  crate 对齐、`agent_ui` 命名、MCP 归 platform）、决策 6（MCP 客户端资产 + v1 平台租赁来源 +
  native 同批）、决策 11（Git 非硬前提，仅 checkpoint 前提）。
- **未落地**：native MCP client（随 native 课程页默认化）；统一会话模型与单 UI（Stage 2）；
  ACP transcript 镜像进 `threads.db` 的隐私/口径尚未补 ADR。
- **文档偏差**：架构脊柱（`_bmad-output/.../architecture-desktop.md`）的 AD-4/AD-5/AD-15/AD-16/AD-17
  文本仍按"仅 ACP"描述；该目录被 `.git/info/exclude` 本地忽略，修订需人工同步到可追踪文档。

## 需要修订的既有决策

| 文档 | 现状 | 修订 |
|---|---|---|
| 脊柱 AD-4 | 不实现 native agent / LLM 客户端 / 工具沙箱；agent 唯一启动组件是 `platform::agent` | **已确认（2026-10-25）**：双轨，native 默认、external 高级；`platform::agent` 继续负责 external；native 走 `agent_*` crate；UI 归 `agent_ui`。脊柱文本待人工同步 |
| AD-5 | MCP 只在 ACP `session/new` / `session/load` 注入 | **已确认（2026-10-25）**：客户端持有唯一 MCP 资产并按 session 下发；ACP 注入 `mcp_servers`，native 由客户端 MCP client 消费；v1 来源仍只有 `learning_host` lease |
| AD-15 | lease 由 `platform/agent` 持有 | **已确认（2026-10-25）**：lease 归 `platform` 的 MCP 资产层，ACP 与 native 共用；客户端内做 5 工具清单核验 |
| AD-16 | 客户端不落对话 | **已确认（2026-10-25）**：native 会话只存本机 SQLite；外部 agent transcript 归其自身；ACP 镜像进 `threads.db` 的现状需补隐私口径 ADR |
| AD-17 | 桌面与 web 行为一致 | 仅对 external 路径适用；web agent 冻结后此条逐步作废 |
| ADR-0023 | 外部 agent 注册表 | 保留；会话指针扩展为 `(course, agent kind)`；native 不在注册表内 |
| ADR-0025 | 客户端自己就是 ACP Host；不打包 agent | 扩展为双宿主；native 随客户端发布 |
| ADR-0001 | 平台不运行模型、BYO | 保留 BYO；新增 CGC 网关作为可选 Provider（平台提供模型服务） |

## 否决的替代

- **只做 external + 官方网关**：小白仍需装 agent，体验受第三方版本影响，多 mate 不可控。
- **全云 agent**：token 成本、隐私口径、合规与工期都不划算（2026-10-22 讨论）。
- **native 但删除 external**：丢失已建能力与高级用户路径；Zed 也选择双轨。
- **v1 做订阅 OAuth**：ToS 与合规风险高，收益不匹配。
- **直接复用 Zed 代码**：GPL-3.0-or-later，先人裁；本 ADR 只取设计。

## 后果（Consequences）

**正面**：小白下载即用；agent 与客户端同版本，迭代不再受适配器影响；Provider / 审批 / 计量可自主；测试可用 FakeProvider 不烧 token；单二进制无 Node 运行时；多 mate 扩展为「定义 + 工具集」。

**代价 / 风险**：Provider 层、工具运行时、OS 沙箱、Checkpoint/diff、会话与评测是 8–14 人月量级长期投入（checkpoint 改用 Git 后省掉一套自建存储）；桌面 ACP 切共享工作区会导致旧会话指针失配（按 ADR-0022 口径从新对话开始）；**无 Git 时 Checkpoint 能力降级**（native 仍可用，需在 onboarding 与提示里讲清楚）；assistant 工作区需要容量上限与清理入口。双轨维护两套会话 / 审批语义（Stage 2 收敛后成本下降）；模型目录与国内 provider 适配需持续维护；GPL 参考边界需人裁；平台提供模型服务引入隐私、合规与成本风险；单进程崩溃影响 UI，需要监督与恢复设计。

**回滚**：native 以 feature flag 接入；关闭后回到 ACP external 路径；CGC 网关可下线，BYO key 不受影响；external 路径与 `cgc-host` 保持现状。

## 落地

- **P0（2 周）**：ADR 定稿 + `agent_provider` 四件套 + FakeProvider + 一个真 provider（DeepSeek 或 CGC 网关）跑通流式文本。验收：不烧 token 的单测 + 可交互 demo。
- **P1a（6 周）**：`agent_core` turn loop + 读 / 写 / 终端工具 + 审批 + **OS 沙箱（Seatbelt / bwrap / WSL 同批，Windows 无 WSL 时降级审批）** + 本地会话 + **交互核心**（Commands / Events / confirm / notify + AppAction：打开页面、高亮）。验收：课程场景 E2E、审批卡复用、沙箱逃逸/越权用例、交互链路、崩溃恢复。
- **P1b（2–3 周）**：Checkpoint / diff（文件快照、Keep/Reject、Restore）+ 课程页灰度替换 ACP（开关）
  + **native MCP client（与灰度同批，来源为 `learning_host` lease）**。验收：恢复/拒绝/大文件/
  工作区外路径用例、灰度验收、native 与 external 学习工具等价。
- **P2（4–6 周）**：Provider 设置页、模型选择器、用量展示、compaction、CGC 网关配额与对账；**steering / follow-up、slash 命令面板、todo / plan / goal、subagent 进度、create_note AppAction**。验收：三平台真机（含沙箱在 Windows / Linux 的真机回归）。
- **P3**：多 mate 定义下发；OS 沙箱；web agent 退役评估。

## 参考

- Zed agent 架构参考与双轨重复度分析：`docs/plans/2026-10-25-1305-zed-agent-architecture-reference.md`
- 详细设计：`docs/plans/2026-10-22-1500-feat-native-agent-design.md`（分层、接口、turn 流程、工具/沙箱、存储、鉴权、测试、P0–P3）
- Zed Provider 层调研：`docs/tmp/agent-research/zed-provider-layer.md`（快照 zed main @2026-10-21）
- Zed 源码（Provider）：`crates/language_model/src/language_model.rs`、`crates/language_model_core/src/*`、`crates/language_models/src/{language_models.rs,provider/open_ai_compatible.rs}`、`crates/settings_ui/src/pages/llm_providers_page.rs`
- Zed 源码（网关鉴权）：`crates/language_models_cloud/src/language_models_cloud.rs:56-190,391-400`（`CloudLlmTokenProvider`、`authenticated_llm_request`、`x-zed-expired-token` / `x-zed-outdated-token` 重试、402 映射）、`crates/client/src/client.rs:350,1390-1400`（Bearer + 版本头）
- 前期调研：`docs/tmp/agent-research/{zed-native-agent.md,cgc-agent-current-state.md,pi-runtime-and-embedding.md,legion-eval.md,elixir-gateway-candidates.md}`
- 讨论页：`docs/tmp/answers/native-agent-provider-plan.html`

## Stage 3 实现状态追加（2026-10-26）

Stage 3 已按设计文档 `docs/plans/2026-10-26-1000-stage3-capability-convergence-design.md` 落地前三个切片，本 ADR 的旧描述据此修正：

- **native 已是进程内 ACP server**（Phase A）：双轨共用 `AgentConnection`/`HostEvent` ingestion，删除 `HostState::apply`；审批统一为 ACP 形状 `PermissionRequest{options}` + 共享 `permission_card`。
- **`toolPermissions` 仅作用于 native**（路线 A，Zed 对齐）：external ACP agent 的审批由其自身模式/options 决定，客户端只渲染与回传；agent 在 auto 模式自行批准时客户端收不到请求。
- **ACP transcript 落本地 `conversations.db`**（thread_content + sidebar_threads，0600/WAL）：统一历史侧栏、Rename/Archive、每 agent 最近 5 条自动归档、Archive 分桶/过滤；永久清空在 Settings（仅 ACP）。
- **Web 端 agent 与 `cgc-host` 已删除**：原文「external 路径与 `cgc-host` 保持现状」不再成立；桌面是唯一 agent 入口。
- **MCP 暂缓**：3.4 native MCP client 待产品确认白名单（建议 5 个只读课程工具）与第三方 MCP 排期；3.5b 默认 native 依赖 MCP，暂不推进。

## Phase B 进展（Stage 3.6，2026-10-26）

双轨收敛进入「共享视图」阶段（见 `docs/plans/2026-10-26-1000-stage3-capability-convergence-design.md` §13）：

- **分层**：`agent_ui` 提供共享渲染（消息行、审批卡、composer card/footer、subagent 行）；`app/root_view/screens/chat/surface.rs` 提供 `ChatSurface` / `ComposerSurface`（能力位 + send/attach/mention/skill/queue/steer/附件回调）；native 只做 adapter（`NativeAgentView` → 共享数据/回调），不再各自维护一套 composer 行为。
- **能力位**：`ThreadCapabilities` 新增 `attachments/images`；native 全真，external ACP 仅 `config_options/plan/usage`。UI 入口一律按能力位显隐，native-only 能力（模型/thinking/审批 picker、checkpoint、queue/steer、subagent 进度）不得出现在 ACP 轨。
- **临时 flag**：`CGC_NATIVE_SHARED_VIEW=1` 让 native 主 composer 走共享渲染；缺省为 legacy。移除条件：旧视图 `native_agent_view.rs` 删除（B4b）且两轨真机验收通过；删除后回退路径不再存在，需在本 ADR/README 记录。
- **B4b 计划**：先把 `native_thread_state` 中仍被共享层使用的类型迁到 `native_panel_host`/`attachment`，再把 controller 的 `Entity<NativeAgentView>` 改为 host/共享面板入口，最后删除 `native_agent_view.rs`（约 6100 行）与 `native_thread_state.rs`（635 行），预计净删 6000–6400 行（以 `git diff --stat` 实测为准）。
- **剩余依赖**：3.4a MCP Streamable HTTP client 已提交（mock 测试）；3.4b/c（工具注册与两轨注入）待产品确认白名单与真机验证；3.5b 默认 native 仅非课程页生效（课程页默认切换依赖 3.4）。

## MCP 与默认入口（2026-10-27）

- **MCP 只读白名单（3.4a/b/c）**：native MCP client 走 Streamable HTTP JSON-RPC（initialize/tools/list/tools/call，Bearer、SSE/JSON、超时与 401/403 fail-closed、token 脱敏）。只注册 5 个只读课程工具（`mcp:cgc-2046-learning:*`：get_course_content / get_course_revision / get_learning_state / get_role_playbook / get_enrollment_summary）；白名单外一律不注册，只读工具审批分类为 `Allow`（不弹卡）。
- **native-only 注入**：配置与 ACP `session/new` 注入同源（`learning_host` lease + `mcp_endpoint(CGC_API_URL)`），但当前只注入 native `ToolRegistry`；external ACP agent 的 MCP 注入保持原逻辑。无 lease/token → 0 工具（fail-closed），不 panic、不打印 token；`CGC_MCP_ENDPOINT/TOKEN` 仅作 headless 测试 seam。
- **默认 native（3.5b）**：`preferences.nativeAgentEnabled` 默认 true，`resolve_native_agent_enabled` = `CGC_NATIVE_AGENT`（"0" 关闭）> `CGC_NATIVE_AGENT_DEMO` > 设置开关；课程页与非课程页同默认，关闭后回退 External Agent。3.4d（真实平台 MCP 工具调用）真机待验。
- **B4b**：旧视图 `native_agent_view.rs`（约 5850 行）/`native_thread_state.rs`（635 行）尚未删除，等两轨真机验收；删除计划见设计文档 §13.4/§13.6。

## B4b 进展（2026-10-27）

- **`CGC_NATIVE_SHARED_VIEW` 已移除**：composer 两条渲染路径合一后，flag 不再切换任何行为，
  相关函数/枚举/死代码一并删除；附件 chips 只保留 legacy composer 内唯一实现。
- **`native_thread_state.rs` 已删除**：`NativeThreadState`/`PendingPermission` 及状态机迁入
  `native_agent_view/state.rs` 子模块，外部路径为 `native_agent_view::NativeThreadState`。
- **`native_agent_view.rs` 拆为父模块 + 9 个子模块**（`composer`/`rows`/`turn`/`panels`/
  `session`/`input`/`runtime_ops`/`render`/`state`）：纯搬迁、行为不变，父文件 5178 → 约 2000 行。
- **`native_agent_view.rs` 已删除**：模块根迁到 `native_agent_view/mod.rs`（411 行，只留类型、
  结构体与 `mod` 声明），其余代码拆入 `panel`/`composer`/`rows`/`turn`/`panels`/`session`/
  `input`/`runtime_ops`/`render`/`widgets`/`state`/`tests` 12 个子模块。
- **净删**：按 Phase B 起点（6730 行）计当前 5925 行，净删 805 行；剩余为 native 专属运行时胶水，
  继续减少需要把这部分迁入共享会话视图适配层（后续独立切片）。

## 会话与运行时所有权收口（Plan 002，2026-10-27）

- **`ConversationSession`（`app/src/conversation_session.rs`）成为两轨唯一的客户端会话 owner**：持有
  `AcpHost`、连接阶段（`ConnectionPhase`）、session/thread id、连接 generation、`ConversationThread`、
  提交队列与 `QueueMode`。视图不再保存 `Option<Agent>`、不缓存 cancel/steer 句柄、不维护第二份 `busy`。
- **generation 前置校验**：`ingest`/`drain`/`mark_ready_for_next` 先比较连接 generation 再归约；被替换的
  连接既不能改内容/标题，也不能释放队首或把 terminal 当成资源就绪。
- **就绪证据分离**：`TurnEnd` 只清空在途提交；队列放行只认 owner 的 `RuntimePhase::Idle` 快照
  （`mark_ready_for_next`）。`Stop` 只暂停队列，不清空用户输入。
- **native owner 唯一持有 Agent**：`NativeRuntimeHandle` 可克隆的只有命令 sender；`NativeAgentView`
  通过 `NativeRuntimeEvent` 订阅读写分离的 `NativeRuntimeSnapshot`。turn 的取用与归还都在 owner 的
  执行任务内完成，视图不再有 `awaiting_agent` 补取轮询。
- **Busy 语义**：活跃 turn 期间 `open_thread`/`new_thread`/`switch_scope` 返回 `Busy`，线程内容、世代与
  选中状态保持不变（`tests/native_runtime_busy.rs` 以红→绿变异验证钉住）。
- **组合根授权**：`RootView` 构造唯一 owner 并显式注入账户 epoch 与 `McpContext`；登录、工作台切换、
  lease 更新/撤销、登出、游客/演示入口都走同一 `prepare_agent_authorization` /
  `revoke_agent_authorization`，撤销先同步 `revoke()` 再异步吊销 token。
- **scope 归属**：`agent_scope` 不再有进程全局 `current()`；scope 由 RootView 显式解析后经
  `switch_scope` 命令切换，render 期不再隐式改所有权。
- **page context 归属**：`PageContextState` 由 RootView 持有并克隆给面板；提交时 `freeze()` 同时冻结
  结构化上下文与 prompt 前缀，独立 controller/演示窗口不互串。

## 取消/超时/队列与持久化收口（Plan 003 + 004，2026-10-28）

- **取消可唤醒**：`CancelToken` 增加 waker 注册与 `cancelled()`；`run_stream` 与压缩流都用
  `select(stream.next(), cancelled())`，模型沉默时 Stop 也能立即收尾。
- **插话按 turn 边界生效**：对齐 Zed 的 `end_turn_at_next_boundary`——steer 不进流循环，只在
  「一轮完成且没有待执行工具」的边界消费，已产生的文本保留。流内竞争与 futures 通道迁移均已回退。
- **执行侧撤销**：`ToolContext` 增加 `CancelProbe`，owner 每轮桥接取消令牌；`run_command` 命中取消
  即按进程组 SIGKILL 并 `wait` 回收（超时路径同样按进程组），MCP 工具在入口拒绝已取消的回合。
- **超时按活跃阶段**：ACP client 的 turn 预算改为空闲预算，只有连续无 `session/update` 才判超时；
  审批等待与长工具执行不再吞掉生成预算。
- **审批取消优先**：`PermissionBridge` 用 `select_biased!` 优先取消，并在解析 `Selected` 后再次确认
  turn 未被取消，迟到许可一律按 Deny。
- **持久化（add-only）**：`thread_snapshots` 投影表（ACP 与 native 各一），未答审批降级为失效
  Warning Notice、已答保留决定、`status` 不参与恢复；单后台 writer 负责合并/序号作废/flush；
  native turn 收尾把执行内容与投影放在同一事务。删除与清空会一并清投影，读侧另有孤儿守卫。
- **启动不碰钥匙串**：`factory::initialize` 只读 `CGC_AGENT_API_KEY`，有 provider 但无 env key 时
  记 `Production::pending`，首次 turn 前才解析；真机启动从 8–11s 降到 19.6ms。
- **有界传输**：provider delta 通道改为容量 32 的有界通道，慢消费者产生背压，drop stream 后
  worker 立即退出（不再需要额外的 drain 信号）。
