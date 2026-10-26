# Stage 3 设计定稿：桌面单端收口与 native/ACP 能力收敛

- 状态：定稿（2026-10-26）
- 分支：`stage3/design`（基于 `chore/remove-web-agent-cgc-host`，HEAD `d8c401b3`）
- 前置：Stage 2 已完成并真机验收（native 真实 provider + ACP 全清单 PASS）；Web 端「学习搭子」与 `cgc-host/` 已删除（`1c686e56`/`a8bdf6d5`/`d8c401b3`）；`feat/native-agent-design` 保持 Stage 2 成果不动。

## 1. 新环境基线

| 项 | 现状 |
|---|---|
| Agent 入口 | 只有桌面客户端：native（CGC Agent）+ External Agents（omp / Codex 等 ACP agent） |
| 本机 Host | `cgc-host/` 已删除；桌面客户端通过 platform registry 管理外部 agent 安装/启动 |
| MCP | 平台侧 MCP server 保留；ACP 轨由桌面客户端注入 MCP 配置；native 尚未接 MCP |
| 学习上下文 | 课程页不再有专用 Web 对话；桌面课程页仍需把 course/revision/unit 作为上下文交给 agent |
| 历史/持久化 | native 落本地；ACP 主要依赖外部 agent 的 session（待统一） |

结论：Stage 3 的目标从「web/desktop 双端对齐」变为「**桌面单端收口 + native/ACP 双轨能力语义统一**」。

## 2. 决策（已与产品确认）

1. **ACP transcript 落本地库**：与 native 同一套本地会话存储；默认永久保留；设置里提供「一键清空 ACP 历史」；实现对齐 Zed（本地 SQLite、文件权限 0600、明文，不做额外加密）。
2. **审批模型统一**：采用 ACP 形状的 `PermissionRequest { id, tool, args, options }` + `option_id` 回传；选项由请求方提供，UI 通用渲染；native 侧生成 4 档选项（允许一次/本会话允许/允许前缀/拒绝），ACP 侧原样透传协议选项。settings 级 `toolPermissions` 正则规则 **仅作用于 native**（路线 A，Zed 对齐）；external ACP agent 的审批由其自身模式/选项决定，客户端只渲染共享卡与回传选择。
3. **native 改成进程内 ACP server**（Phase A/B，见 §3）。这是本阶段的地基：统一事件契约、权限、配置、MCP 注入与历史存储。
4. **全局 Agent Panel + 课程页只传上下文**：不再有「课程页专用对话」；任意页面默认 native，External Agents 保留；课程页负责把 course/revision/unit 作为上下文附加到 thread，agent 通过 MCP 工具读取课程内容。
5. **MCP 重新讨论放在 native-as-ACP Phase A 之后**：native MCP client 是「所有页面默认 native」的前置条件。

## 3. 为什么是 native-as-ACP（Zed 证据）

XERJ `zed-agent` 语料（sha `07c8d71f`）显示 Zed 不是「两套审批模型硬统一」，而是只有一套：

- `Agent::NativeAgent` 与 `Agent::Custom` 同属 `Agent`，均经 `AgentServer/AgentConnection`（`agent_ui/agent_connection_store.rs:268`）；
- native 用 `agent::NativeAgentServer::new(...)` 后 `.connect(delegate, ...)`，再 `downcast::<agent::NativeAgentConnection>()`（`agent_ui/mention_set.rs:608`）——native 是内嵌 ACP server；
- 权限请求统一为 `acp_v2::RequestPermissionRequest`，通用渲染 `render_generic_permission_card`（`agent_ui/conversation_view/thread_view.rs:4028`），选项由请求自带；
- 选项构造 `ToolPermissionContext::new(tool, inputs).build_permission_options()`（`agent_ui/conversation_view.rs:15917`）；
- 设置级授权规则 `tool_permissions.{default, always_allow, always_deny, always_confirm}`（`zed-ui/.../tool_permissions_setup.rs:1192`）。

结论：native 与外部 agent 在协议层同构后，权限、历史、标题、配置、MCP 注入都只有一套实现。

## 4. 分阶段方案

### Phase A：native 进程内 ACP server（地基，约 4–6 天 / 5–8 commit）

范围：
1. 进程内 transport（`agent-client-protocol 3.4` 自带 `Agent` 角色与 router：`src/acp_agent.rs`、`src/role/acp.rs`）；
2. Server adapter：`initialize`、`session/new`、`session/prompt`、`session/cancel`；把现有 `AgentEvent` 流映射成 `SessionUpdate`（消息、tool_call/update、plan、usage、title、compaction）；
3. 权限：native 审批请求 → ACP `request_permission`（携带 options），用户选择回传为 ACP 响应；
4. native 接入现有 ACP 客户端 ingestion 路径，删除 native 专属 `HostState::apply`/`HostEvent` 映射及其单测；
5. 测试：native server golden 事件序列、两轨同输入同 `ConversationThread` 对照、native 真机回归（工具/审批/Copy/checkpoint）。

暂不做：不删 `native_agent_view`；附件/queue/steer/checkpoint 仍走 native UI；模型/thinking picker 暂不迁到 ACP config options；不接 MCP。

验收：
- native 与 ACP 产出同一 `ThreadEvent`/`ConversationThread`，reducer 单测与对照测试通过；
- native 真机回归全部 PASS（含审批重复行、Copy、checkpoint）；
- 无新增 clippy/fmt 告警，workspace 测试绿（排除已知 flake 与 cgc-agent-tools 本机沙箱用例）。

### Phase B：UI 与能力收口（约 5–8 天）

- native 复用共享 `agent_ui` conversation view，附件/queue/steer/checkpoint 以 capability 迁入共享视图；
- 删除 `native_agent_view.rs`（预计 −4k~−5k 行）；
- 权限卡统一（Phase A 后基本免费）+ settings 级正则规则；
- transcript/历史/标题统一到一处 store（ACP 与 native 同库）。

### 3.x 路线与验收

| 序 | 切片 | 依赖 | 验收 |
|---|---|---|---|
| 3.1 | native-as-ACP Phase A | 无 | 同 [§4 Phase A] |
| 3.2 | 审批模型/权限卡统一 + settings 规则 | 3.1 | 两轨通用权限卡；native 4 档、ACP 透传；设置规则生效；单测+变异验证 |
| 3.3 | ACP transcript + 历史/标题统一 | 3.1 | ACP 重启后本地历史可恢复/搜索；一键清空；与 Zed 行为对照 |
| 3.4 | native MCP client | 3.1 | native 可调平台 MCP 工具；ACP/native MCP 注入同一配置源 |
| 3.5 | 全局 Agent Panel + 课程页只传上下文 + 默认 native | 3.1–3.4 | 任意页面开同一 Panel；课程页自动附加 course/revision/unit；默认 native、External Agents 可选；删除课程页专用 agent 初始化 |
| 3.6 | Phase B：删 native_agent_view + 共享视图收口 | 3.1–3.5 | 两轨同一 thread view；净删行数记录；真机回归两轨 |
| 3.7 | 文档/架构同步 | 全部 | ADR-0028、2026-10-22 plan、desktop 文档补注「唯一入口=桌面」 |

## 5. 明确不做（本阶段）

- 不恢复 Web 端 agent / `cgc-host`；
- 不改 provider/tools/store 运行时语义（仅接 ACP server adapter 与 MCP client）；
- 不做 ACP transcript 加密（本地明文 + 0600，后续单独立项）；
- 不做多用户/多租户历史隔离之外的新权限模型。

## 6. 风险与回退

1. ACP crate server 角色能力边界（如缺 session/load）：退回自写最小 JSON-RPC server，+2–3 天；
2. 进程内 transport 的取消/并发语义：单独测试 cancel、并发 session、断连清理；
3. Phase A 期间 native UI 保持现状，避免一次摊太大；
4. 若默认 native 导致课程工具缺失（MCP 未就绪）：3.4 完成前不改课程页默认，灰度开关保留。

## 7. 验收环境

本地 Phoenix 后端（`localhost:4000`）+ 测试账号 `demo@example.com/demo1234` + 已验证的 native/ACP 真机回归流程；测试数据只落 `/tmp` 隔离目录，不碰真实 data/keychain/Host。

## 8. Phase A 实现与真机验收记录（2026-10-26）

实现分支 `stage3/design`：

| commit | 内容 |
|---|---|
| `3ca36397` | native 进程内 ACP server 地基（transport + server adapter + 权限桥 + cancel/守卫） |
| `f87788a8` | 双轨共用 `HostEvent` ingestion + 两轨对照测试 |
| `0722b2e4` | native 面板经进程内 ACP 接线，删除 `HostState::apply` 映射 |
| `0984b845` | 自审修正（tool 支持门控、awaiting 交回期间不丢队列） |
| `11086a76` | 删除迁移后不再使用的 `AsyncChannelObserver` |
| `290c768e` | 真机审批两 bug 修复（已解决行不更新 / 第二轮审批卡丢失 + timeout） |

门禁（Lead 独立复跑）：`cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、
`cargo test --workspace --exclude cgc-agent-tools` → **467 passed / 0 failed**。

真机验收（native + 真实 DeepSeek + 本地后端，2026-10-26）：
- 第一轮 `run_command` 审批 → 允许一次 → 审批行变「已允许」、工具卡完成、输出 `hi`、退出码 0；
- 紧接着第二轮同句 → **审批卡正常再次出现** → 允许一次 → 回合正常结束，无 Stop 常亮 / 无 `turn timeout`；
- 回合末操作栏存在「Copy This Agent Response / Scroll to User Message / Scroll to Top / 编辑消息 / 恢复检查点」；
- 整回合 Copy 复核：剪贴板为完整回合文本（含 ```bash 代码块与退出码说明）。

未在本轮冒烟中重新点击验证：恢复检查点/编辑重发（Stage 2 已验证过，Phase A 只换事件来源，未改 checkpoint 逻辑）；
Phase B 的共享视图/能力迁移仍按 §4 待做。

## 9. Stage 3.2a 实现与真机验收（2026-10-26）

| commit | 内容 |
|---|---|
| `2dd17575` | 共享模型：权限请求携带 ACP 形状 `options`（id/label/kind） |
| `3f130641` | `agent_ui::permission_card` 两轨共享审批卡（纯 view + 渲染 + 单测） |
| `d0ab200a` | native/ACP 接线共享卡 + `option_id` 回传、删除各自硬编码按钮 |

门禁（Lead 独立复跑）：fmt ✅、clippy `-D warnings` ✅、workspace 测试 **477 passed / 0 failed**。

真机验收（native + ACP 两轨，2026-10-26）：
- **ACP（omp）**：审批卡由共享组件渲染，选项来自 agent（`Allow once / Always allow / Reject / Always reject`），
  点 Allow once → 工具卡 `Execute completed`、输出 `hi`；历史行显示「已允许」卡片，状态正确；
- **native（CGC Agent）**：审批卡同组件渲染，4 档选项「允许一次 / 本会话允许 / 本会话允许 echo 前缀 / 拒绝」，
  顺序与样式正确，`option_id` 回传生效；
- 两轨均显示「选项由请求方提供，选择会原样回传给 agent」footnote；pending 卡在第二轮复现正常（Phase A 修复保持）。

未在本轮真机点击：native「允许 echo 前缀」具体按钮（带 `:` 的 option id）、Always reject、Ctrl+Shift+Y/N 快捷键、
ACP agent 自定义非标准 options；已由纯函数/两轨对照测试覆盖，建议后续回归顺带点一次。

已知小问题：旧 native 线程可能残留「Native agent：配置 Provider 后开始对话」的历史 Notice（创建线程时 provider 未配置所致），
新回合不影响；3.3 历史统一时清理。

3.2b（settings 级 always allow/deny/confirm 正则规则）待做。


## 10. Stage 3.2b 最终行为与真机验收（2026-10-26，路线 A）

| commit | 内容 |
|---|---|
| `18ad30d0` | settings 级审批规则（native 规则引擎，`toolPermissions`） |
| `74abd289` | Revert 通配键/ACP 自动决定（放弃路线 B） |
| `07f21256` | `toolPermissions` 改为 native-only + 文档（Zed 对齐） |

门禁（Lead 独立复跑）：fmt ✅、clippy `-D warnings` ✅、workspace 测试 **502 passed / 0 failed**。

最终行为：
- **native**：`toolPermissions` 生效（精确工具名；`deny > allow > confirm > default(ask)`；非法正则容错）。命中 allow/deny →
  不弹卡、自动回传 option + system Notice、不产生 Permission 行；ask/confirm → 共享审批卡；Auto 模式仍走 runtime `AutoApprover`，不叠加规则。
- **external ACP**：规则**不生效**；收到 `request_permission` 一律渲染共享审批卡，按钮来自 agent 的 options，用户选择后 `option_id` 原样回传。
  agent 自身处于 `auto` 模式并自行批准时，客户端收不到请求，规则/拦截不适用（ACP 协议事实）。
- 真机验收：native `run_command.alwaysDeny:["echo"]` → 自动拒绝 Notice + 工具失败 + 回合正常结束；
  同规则下 OMP（ask/default）仍出现共享审批卡，点 Reject → 历史行「已拒绝」、工具 `failed`、回合正常结束。
- 无设置 GUI（手改 `preferences.json`，即时生效）；`desktop/README.md` 已写规则说明与 ACP 模式限制。

## 11. Stage 3.3 / 3.3b 实现记录（2026-10-26）

3.3 数据层（Zed ThreadStore + metadata 语义）：

| commit | 内容 |
|---|---|
| `e6e16bc7` | `conversations.db`（thread_content + sidebar_threads，0600/WAL/迁移/容错） |
| `a8f9c23c` | ACP transcript 落库、统一历史、标题/override、恢复降级、设置清空 |
| `f7c08560` | `session/load` 回放替换 / 失败降级 e2e |

3.3b 历史交互（Zed 对齐）：

| commit | 内容 |
|---|---|
| `6c7fafa6` | 全局历史 + Rename/Archive/自动归档/Archive 视图（P0 三 bug 修复） |
| `bcabb9c2` | 历史从模态改为 Zed 式左侧边栏 |
| `e52872e2` | 行操作改为 hover 铅笔/归档图标（对齐 Zed ThreadSwitcher 行） |
| `cf7896c0` | Agent Panel `⋯` 菜单 Toggle Threads Sidebar + `⌥⌘J` |
| `60565a17` | native 行归档（`native_archived` 迁移，不改 threads.db） |
| `02c066ad` | 各 Agent 品牌图标（native 应用 logo；codex/claude/opencode 官方 ACP registry SVG；omp 单色 mark） |
| `1cfe945e` | OMP 单色 currentColor 修复 + 单色资产守卫测试 |

实现要点：
- 历史侧栏：最近（按 agent 分组）/归档（今天/昨天/最近 7 天/更早分桶 + 过滤）；行首品牌图标；hover 铅笔/归档/取消归档；行正文点击打开，侧栏保持并高亮；`＋` 按当前轨新建。
- Archive 仅隐藏；永久删除只在 Settings「清空 ACP 对话历史」（native 不受影响）；ACP 每 agent 最近 5 条自动归档。
- `#` 事件冒泡 bug：历史行不再挂整体 on_click，菜单位置与打开区域为兄弟节点；`×` 裸删除已移除。
- 真机已复现并修复的 bug：× 无响应、native 模式历史入口消失、清空后列表不刷新。
- 品牌图标资产来源：Codex/Claude/OpenCode 取自官方 ACP registry CDN 对应 agent icon，OMP 取自 omp.sh 单色 mark；仅用于标识对应 agent；若需法务/设计替换，渲染层不变。

门禁（Lead 独立复跑）：fmt ✅、clippy `-D warnings` ✅、workspace 测试 **536 passed / 0 failed**（registry 网络 mock 用例偶发超时，重跑即绿，既有 flake）。

真机待最终确认（用户复验）：侧栏开关/高亮、hover 图标、Rename 持久化、Archive/Unarchive、过滤/分桶、清空刷新、品牌图标观感。
