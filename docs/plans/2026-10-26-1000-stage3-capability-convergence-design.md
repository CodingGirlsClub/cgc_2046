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
2. **审批模型统一**：采用 ACP 形状的 `PermissionRequest { id, tool, args, options }` + `option_id` 回传；选项由请求方提供，UI 通用渲染；native 侧生成 4 档选项（允许一次/本会话允许/允许前缀/拒绝），ACP 侧原样透传协议选项；settings 级 always allow/deny/confirm 正则规则为二期。
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
