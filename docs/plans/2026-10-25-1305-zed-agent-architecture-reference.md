# Zed agent 架构参考：native 与 ACP 为什么不是两套 UI，以及我们的改进路线

> 日期：2026-10-25 ｜ 性质：**参考分析（research），不是决策记录**。决策请走 ADR。
> 证据基线：Zed 源码 `zed-industries/zed@347f171a`（2026-10-24，含 PR #61245 / #61362）；
> 检索用 xerj 索引 `myref-docs`（Zed 快照 run-20261019，locator 级一致，细节以本地源码为准）；
> 本仓 `feat/native-agent-design@1eb3e586`。
> 范围：`desktop/` 的 agent 架构；不含后端、web、小程序。
> 限制：全部为静态源码阅读 + 交叉核对，**未跑 GUI / 未做真机并排截图**；行数为 `wc -l` 或函数边界估算。

---

## 0. 结论先行

1. **Zed 是「一套 UI + 一个客户端会话模型 + 两个 agent 运行时」**，不是「一套 agent 实现」。
   `ThreadView` 只渲染 `acp_thread::AcpThread`；生产代码里 `ThreadView::new` 只有 1 个调用点；
   "Copy This Agent Response" 的 UI 实现只有一处（`thread_view.rs`：按钮 `:7952`、右键菜单
   `:8771`，共用同一个 `get_agent_message_content`）。native agent 只是 `AgentServer` 列表里的一项。
2. **我们是「三处两套」**：事件契约、视图模型、会话驱动各一套；消息操作栏只是最表层的症状。
   ADR-0028 决策 2 自己写的「UI 只消费 `HostEvent`/`HostCommand`，新增 `NativeHost` 实现同一接口，
   不新增第二套对话 UI」**一行都没落地**——实际新增了 `AgentCommand`/`AgentEvent`/`HostState`，
   且没有 `NativeHost` 类型（全仓 grep 为空）。
3. **最近 4 个 commit 抄的是 Zed 的 #61245，漏了它的收尾 #61362**：我们让**每条** assistant 消息
   都挂操作栏，Zed 最终只在「回合末（finalized turn end）」挂；且我们在 streaming 时把历史消息的
   操作栏也全部隐藏，Zed 只隐藏底部那条。表现为「工具调用边界随机冒出按钮」——正是 #61362 修的 bug。
4. **重复量≈4,500 行**（14 项能力，native≈2,650 / ACP≈1,860），抽公共层可净删 ≈1,100–1,600 行
   （估算）。但**根因不是 UI 重复，是缺一个客户端会话模型**；只合并展示层会在下一个功能上再分叉。
5. **建议**：先做 parity 修复（小时级）→ 抽共享消息流/composer（天级）→ 补统一会话模型 + 单 UI
   （1–2 周）→ 能力收敛。`provider`/`tools`/`sandbox`/存储、MCP/registry 不合并（运行时差异，不是重复）。

---

## 1. Zed 的分层与 seam

```
agent_ui         AgentPanel(14814) → ConversationView(20827) → ThreadView(15477)
                                   │ 只读 Entity<AcpThread>（唯一消息 UI）
acp_thread       AcpThread{ entries, permission_requests, submissions, subagents,
                 token_usage/cost, checkpoint, notices, plans, streaming }
                 + 单一 reducer handle_session_update()
                                   │ Rc<dyn AgentConnection>
                 ┌─────────────────┴──────────────────┐
agent            NativeAgentConnection（进程内）      agent_servers：
                 agent.rs 10290 + thread.rs 9791      AcpConnection v1(10393) /
                                                      AcpV2Connection v2(7767) + stdio
                 └─────────────────┬──────────────────┘
agent_client_protocol   schema v1/v2 纯类型 + transport SDK
```

依赖方向（`Cargo.toml` 证据）：

| crate | 角色 | 依赖 |
|---|---|---|
| `acp_thread` | 客户端会话模型 + `AgentConnection` trait + 单 reducer | 协议类型、project、git_store、markdown |
| `agent_servers` | `AgentServer` 端口 + ACP v1/v2 实现 + stdio | `acp_thread`、协议 transport |
| `agent` | native 运行时（provider/tools/thread/tool_permissions/sandboxing） | `agent_servers`、`acp_thread` |
| `agent_ui` | 唯一 agent UI | `acp_thread`、`agent_servers`、`agent`（少量 downcast） |
| `agent_settings` | profile / 权限模式 / 模型档位等跨 agent 设置 | 不依赖任何 agent 实现 |

**两个 seam（照抄价值最高）**：

1. `AgentServer` 是窄端口（`crates/agent_servers/src/agent_servers.rs:51`）：
   `logo / agent_id / connect / into_any`。agent 种类 → 实现的映射收敛在**一个工厂**
   `agent_ui.rs:579 Agent::server()`，UI 其它地方不再 match agent 枚举。
2. `AgentConnection` 是宽端口（`crates/acp_thread/src/connection.rs:95`）：
   `new_session / load_session / resume_session / close_session / cancel / auth /
   model_selector / truncate / set_title / retry / delete ...`；
   可选能力用**独立小 trait + `Option<Rc<dyn ...>>`** 暴露（`AgentSessionTruncate`、
   `AgentModelSelector`、`ReceiptSessionSubmissions`…），不用 bool 堆在主 trait 上。
3. `AcpThread` 把连接做**字段**（`Rc<dyn AgentConnection>`，`acp_thread.rs:3552`），
   所以 UI 拿到线程就能问「这个 agent 支持什么」，永远不需要知道 agent 是 native 还是 ACP。

---

## 2. 「只有一套 UI」的证据

### 2.1 单一构造点与无 agent 分支的渲染函数

- `ThreadView::new` 生产调用点：`crates/agent_ui/src/conversation_view.rs:1729`（全仓唯一）。
- 消息操作栏：`thread_view.rs:7933 render_thread_controls(&self, thread: &Entity<AcpThread>, entry_ix,
  copy_response_index, is_thread_bottom, user_message_index, cx)`——签名与函数体都没有 agent 类型。
- 右键菜单：`thread_view.rs:8742 render_message_context_menu(entry_ix, markdown, ...)`，同理；
  与按钮**共用** `get_agent_message_content`（`:8855`），没有第二份复制逻辑。
- 测试用 `StubAgentServer`（纯 ACP stub）驱动同一 `ThreadView`：
  `conversation_view.rs` 里 `MENU_ITEM-Copy This Agent Response` 的断言（`:12066`）就是证据。

### 2.2 三类「分支」= 一个 UI 内核 + 能力位 + 少量逃生口

| 机制 | 位置 | 形态 |
|---|---|---|
| 能力方法 | `connection.rs:117/134/156/175/180/196/258/347/543` | `supports_x()` 或 `Option<Rc<dyn Capability>>`，UI 据此显隐 |
| 协议数据 | `PromptCapabilities`（image/embedded_context，`message_editor.rs:79`）、`available_commands`、`PermissionOptionKind` | server 上报什么，UI 就支持什么 |
| native 逃生口 | `as_native_connection:1477` / `as_native_thread:1485` | 全 `agent_ui` 仅 **45 处**，全是装饰件（profile 选择、token 上限 callout、diff loading、Steer、模型名文案） |

**checkpoint / restore 是澄清我们疑虑的最好例子**：实现和 UI 都是共享的
（`acp_thread.rs:7593 restore_checkpoint`：先 client 侧 `git_store.restore_checkpoint`，再 `rewind:7626`；
UI `thread_view.rs:7295-7345` 只判 `can_rewind_to`），**唯一 native-only 的是
`impl AgentSessionTruncate`（`agent.rs:3584`）**；外部 ACP agent 默认 `truncate() = None`，
于是编辑/重发/Restore 按钮整体隐藏。即：**能力位决定显隐，不是两套 UI**。
（ACP schema 1.12 没有 rewind 方法，这是 Zed 的客户端侧能力私约。）

### 2.3 消息操作栏的最终形态（#61245 + #61362）

- 只在**回合末**渲染：`entry_is_finalized_turn_end`（`thread_view.rs:7912`）——后面遇到 UserMessage
  才是 true；后面还有 AssistantMessage/ToolCall 就是 false；调用点 `:7703`。
- thread 底部条（scroll-to-top / turn stats / feedback）只在**线程最后一条**：
  `:7731` 兜底 + `:7976`/`:7985`/`:8019`。
- 底部条在 generating / 等审批时隐藏（`:7946-7948`）；**历史消息的条在 streaming 时仍可见**。
- 样式：`h_flex().justify_end().opacity(0.4).hover(opacity 1.0)`（`:8084`），按钮 ID 用 `(name, entry_ix)` 唯一化。
- 复制语义：`get_agent_message_content`（`:8855`）以「上一个 UserMessage+1 ～ 下一个 UserMessage-1」
  为范围，收集该回合**所有** assistant 文本块、跳过 Thought → **复制的是整回合文本，不是一个气泡**。

### 2.4 我们 vs Zed 的行为差（可直接修的 parity）

| # | 行为 | Zed | 我们 |
|---|---|---|---|
| 1 | 操作栏挂载点 | 只挂 finalized turn end | **每条 assistant 消息**（`native_agent_view.rs:2595 if !self.busy`；`chat/panel.rs:227 phase == ChatPhase::Ready`）→ 复现 #61362 的 bug |
| 2 | streaming 时历史消息操作栏 | 可见 | 全部隐藏 |
| 3 | Scroll to Top | 仅线程底部 | 每条消息都有 |
| 4 | Copy This Agent Response | 整回合文本（跳过 thinking） | 单条 `message.text`（native） / 单条 `text`（ACP） |
| 5 | 按钮视觉 | opacity 0.4 → hover 1.0 | ACP 有；native 是 muted icon + hover 背景 |
| 6 | 反向依赖 | — | ACP 面板 `chat/panel.rs:285` 反向 import native 的 `markdown_to_plain` |

> 我们最近两个 commit 分别只覆盖了 #61245（每条都挂）和它的 ACP 对齐；
> 建议直接补 #61362 的收尾，并把上面 6 项收敛成「一份 gating + 一份 copy payload」。

---

## 3. 我们的现状：三处两套

| 层面 | ACP 轨道 | native 轨道 | 判定 |
|---|---|---|---|
| 事件契约 | `platform/src/acp/connection.rs:124 HostEvent` / `:161 HostCommand` | `agent_host/src/events.rs:7 AgentEvent` / `commands.rs AgentCommand` | 职责 100% 对位，**无互转代码** |
| 视图模型 | `root_view.rs:197 ChatPhase` / `:207 ChatEntry`（5 变体，tool 只有 title+kind）/ `:226 ChatUi` | `agent_host/src/state.rs:66 HostState` / `:34 UiMessage` / `:7 UiRole`（args/status/content/usage/subagent/streaming 齐全） | ACP 模型信息量不足，无法渲染 native 级的工具卡/用量/子 agent |
| 会话驱动 | `controller.rs:1125 drain_chat_events`（174 行）+ `:902 start_chat`（204 行），轮询 stdio | `native_agent_view.rs:1367 run_turn`（192 行），进程内 async + TurnObserver | 两套状态机 |

**UI 侧重复量化**（函数边界估算，±10–15%）：

| 能力 | native 位置 / 行数 | ACP 位置 / 行数 |
|---|---|---|
| 消息行渲染 | `native_agent_view.rs:2553/3154/4862/5362` / ≈415 | `chat/panel.rs:165-430` / ≈265 |
| 消息操作栏 | `:2987/4837` / ≈74 | `panel.rs:227-273/1256` / ≈78 |
| 右键菜单 + 复制载荷 | `:5387/5216/5233` / ≈160 | `panel.rs:1287` + `root_view.rs:381` + `controller.rs:1514` / ≈90 |
| 滚动/follow | `:3234/3065/3036/3101` / ≈149 | `controller.rs:1537-1554` / ≈28 |
| 审批卡 + 审批模式 | `:3387-3500/2538/3875` / ≈277 | `panel.rs:359-430` + `controller.rs:1646` / ≈103 |
| 工具卡 | `:5066/5057/2116` / ≈113 | `panel.rs:338-357` / ≈34 |
| composer | `:4040-4474` / ≈435 | `panel.rs:700-860` / ≈160 |
| slash | `agent_host/slash.rs` + `:4100-4704` / ≈340 | `root_view.rs:292-380` + `panel.rs:455-540` / ≈235 |
| 模型选择 | `:1681/3677-3960` / ≈288 | `panel.rs:545-790` + `controller.rs:1677` / ≈284 |
| 错误态/重试 | `:2933/5537` / ≈101 | `panel.rs:52-170` / ≈130 |
| 流式/thinking | `:2899/2851/4971` / ≈147 | `panel.rs:432-443` / ≈45 |
| 标题 | `:1172` / ≈110 | `root_view.rs:560/3862` / ≈45 |
| 历史/会话 | `open_thread/start_new_thread` ≈99 | `panel.rs:850-1020` + `controller.rs:1714-1806` / ≈365 |
| **合计** | **≈2,650** | **≈1,860** |

**已统一的部分**（说明公共层可行）：面板外壳 header（`chat/agent_panel.rs:100`，360 行）、
Markdown 渲染（`TextView::markdown` + `sanitize_markdown`）、主题 palette；
ACP 复制纯文本已经**反向 import** native 的 `markdown_to_plain`（`chat/panel.rs:285`）——
seam 已经在裸奔，只是没抽出来。

**持久化三处写、三种 schema**：

| 轨道 | 存储 | 恢复 |
|---|---|---|
| native 会话 | `agent_store::SessionStore`（SQLite `threads.db`，strong-typed JSON） | `open_thread` 从 Entry 重建 `HostState` |
| native checkpoint | Git 隐藏 ref `refs/cgc/checkpoints/<thread>/<seq>` + `threads.db` 元数据 | `restore/diff`，HEAD 漂移检测 |
| ACP | 外部 agent 自己持有 transcript；客户端只有 `chat_state.json` 指针 + prefs | `session/list` + `session/load` |
| **跨轨** | ACP 会话被 `persist_acp_thread`（`controller.rs:1379-1480`）**有损镜像**进 `threads.db`，供统一列表 | 列表统一了，**恢复语义没统一**（仍走 `session/load`） |

**文档与代码的偏差**（影响「双轨到底是不是长期形态」的判断）：
- ADR-0028 仍是 `status: proposed`（`docs/adr/0028-desktop-native-agent-dual-track.md:2`），
  但代码已冲到 P1b/P2。
- 架构脊柱 AD-4（`_bmad-output/.../architecture-desktop.md:76`）仍写「不实现 native agent、LLM 客户端与工具沙箱」；
  `desktop/AGENTS.md:32` 仍写「故意不做：native agent」。
- ADR-0028 决策 2「单一 HostEvent/HostCommand 契约 + NativeHost」未落地；
  决策 3「UI 归 `agent_ui`」未落地（该 crate 是 **31 行 doc 桩**，ACP UI 在 `app/root_view`，
  native UI 在 `app/native_agent_view.rs`），app 不再是纯组合根。
- ADR-0028 决策 6（native 经 MCP 拿学习工具）、决策 11（Git 为硬前提）未实现 →
  **双轨能力不等价**：native 目前做不了课程学习工具。
- AD-16「客户端不落对话」与「ACP transcript 镜像进 `threads.db`」冲突，属新决策，未被任何 ADR 覆盖。

---

## 4. 值得学 / 值得避

### 4.1 值得学（按复用价值排序）

1. **客户端会话模型是唯一收敛点**（`AcpThread`）：entries、permission_requests（`oneshot::Sender`
   直接存在模型里，待决请求天然可枚举）、submissions、subagents、token_usage/cost、checkpoint、
   notices、plans、streaming buffer；连接是字段。
2. **单 reducer + 按条目索引的事件**：`AcpThreadEvent` 24 个变体分三类（结构变更带 index /
   请求生命周期带 id / 元信息）；UI 只 `sync_entry(index)` + `remeasure_items(index..index+1)`
   （`conversation_view.rs:2002-2016`）。模型与行内 UI 状态分离（`EntryViewState` 存展开态/编辑器/终端）。
3. **流式缓释**：token 到达只加 `pending_bytes`，权威文本不动；`TASK_UPDATE_MS=16` /
   `REVEAL_TARGET=200ms` 追平（`acp_thread.rs:3635-3660, 5561-5590`）。
   好处：native/ACP 手感一致、与上报粒度解耦、复制/导出永远拿权威文本。
4. **提交可靠性三态**（`submission.rs:164-175`）：`Completion`（prompt 响应=回合结束，v1）/
   `Receipt`（先 ack，前台状态另报，native+v2）/ `AgentOwned`（subagent，客户端不能提交）。
   状态机 `Pending → Accepted{echoed} / Disconnected / Completed / Failed / Cancelled`，
   `observe_echo` 把 agent 回显 id 与本地乐观条目对账；`Disconnected` = 「接受未知」而非失败。
5. **能力表达**：`supports_x()` + `Option<Rc<dyn Capability>>` 双轨，而不是 agent 枚举 match；
   协议能力（`PromptCapabilities`/`available_commands`/权限选项）直接裁剪 UI。
6. **持久化所有权分离**：native transcript 归 `agent::ThreadStore`；**所有** agent 的索引
   （session_id/agent_id/title/worktree/archived）归 `ThreadMetadataStore`；外部 transcript 归 agent 自己，
   靠 `load/resume` 协商取回；构造期用 `Option<TranscriptStore>` 区分（`agent_panel.rs:4664`）。
7. **checkpoint 是客户端资产**：挂在每条 user message 上，restore = cancel → rewind → git restore；
   能力由 `truncate` 决定 → 天然可给外部 agent 用（协议支持后）。
8. **入站保序与兼容**：所有协议回调进 per-connection 单前台 dispatch 队列
   （`acp/runtime.rs:26`）；session 响应未回、通知先到 → `PendingSessionUpdates` 有界暂存
   （1024 条 / 16MB，溢出显式标记）；未知 update 降级返回交上层，不崩。
9. **取消两段式**：发 cancel（v1 只发 notification）→ 等 `activity.wait_for_idle()`；
   新 prompt 先 `InterruptedByFollowUp` 抢占上一回合。
10. **native 不需要假协议**：复用 `acp_v2` 类型、实现端口即可；入站两条路径
    （外部走协议回调、native 直接调用），能力实现（fs/terminal）放模型层共用。
11. **UI 三段式**：AgentPanel（导航/所有权）→ ConversationView（连接生命周期）→ ThreadView（纯渲染）；
    agent 工厂只有一个入口。抄这个结构，Copy 类按钮天然只落 Thread 段一次。

### 4.2 值得避

1. **native 双份状态**：`agent::Thread`（执行域，`messages: Vec<Arc<Message>>`）经 `ThreadEvent`
   单向镜像进 `AcpThread`；外部 agent 没有这层镜像。我们若做，最好让 native 直接写共享模型，
   或明确「视图域只读、执行域单向可写」并测试一致性；否则中途失败/重试的一致性成本会反噬。
2. **UI 里 native downcast 会随功能增长膨胀**（Zed 已 45 处）。约定：核心路径必须 agent-agnostic；
   装饰件可 native-only，但必须 Optional 且集中在少数文件。
3. **超大文件**：Zed `thread_view.rs` 15477 行、`conversation_view.rs` 20827 行是反面教材；
   我们 `native_agent_view.rs` 6090 行已经违反本仓「手写文件 <500 行」约定，抽取时按
   Row / Composer / Actions / Checkpoint 拆文件。
4. **不要全量合并**：checkpoint/queue/subagent/plan、provider/tools/sandbox、MCP lease/registry
   是运行时能力，不是重复；合并只会造错抽象。
5. **feedback 上传**（Zed 会把整个会话发给官方）不抄；只抄入口位置与 gating 方式。

---

## 5. 建议路线（分阶段，保持可发布）

### Stage 0：parity 修复（小时级，独立可合）

- P0-1 操作栏改「回合末」：给两套实现加 `is_finalized_turn_end` 判定
  （后面还有 assistant/tool → 不挂；遇到下一条 user → 挂；线程末尾按 `!generating` 兜底）。
- P0-2 `Scroll to Top` 只在线程底部；如加 turn stats/feedback，也只底部。
- P0-3 streaming 时保留历史消息操作栏，仅隐藏底部条。
- P0-4 统一 Copy 语义（建议按 Zed：整回合文本、跳过 thinking；若产品要单条，也必须两轨一致）。
- P0-5 把 `markdown_to_plain` / `sanitize_markdown` / clipboard payload 移出 native view，
  消除 `panel.rs → native_agent_view` 反向依赖。
- P0-6 文档补课：`desktop/AGENTS.md`、架构 AD-4、ADR-0028 状态与决策 2/3/6/11 的偏差；
  为「ACP transcript 镜像」补一条 ADR（含隐私口径）。
- P0-7（顺带发现，待验证）：native 实时视图的条目顺序可能和持久化重载不一致——
  `HostState` 在 `ToolCallStarted` 只 flush thinking、不 flush streaming（`agent_host/src/state.rs:155`），
  assistant 文本要等 `TurnFinished` 才落一条消息（`:190` 附近）；而 `apply_thread_entries`
  重载时按 `Entry` 顺序生成（`native_agent_view.rs:399`）。若模型在工具调用前吐过文本，
  实时顺序会是「工具卡 → 文本」，重开线程后变成「文本 → 工具卡」。
  **静态推断，需一条单测确认**；统一 reducer 时顺手把「工具卡前 flush 文本」钉住。

### Stage 1：抽共享消息流与 composer（天级，不碰契约）

- 定义只读 `Row` 模型（User / Assistant / Thinking / Tool{name,args,status,content} /
  Permission{id,scope,resolved} / Error / Streaming），两条轨道各写 ~30–50 行 mapper。
- 共享：行渲染 + markdown + 操作栏 + 右键菜单 + copy payload + mention chip；composer（能力用 props）。
- ACP 消息列表切到 `gpui_kit::component::message_scroller`（native 已在用），
  `previous_user_*` 两份合成一份。
- 验收：两轨各一条真机路径；变异验证（改坏复制范围/滚动映射必须红）；净删 ≥800 行。

#### Stage 1 实测（2026-10-25 起，逐 commit 统计）

| commit | 内容 | app 视图层 | agent_ui | 总 LOC |
|---|---|---|---|---|
| `6f3561bc` 1a | message_flow / markdown_text 迁入 | -457 | +510 | +55 |
| `a3db819d` 1b | 共享操作栏 + 右键菜单渲染 | -101 | +185 | +85 |
| `d9ae1dc6` 1c | 共享 Markdown 视图/净化 | -41 | +57 | +18 |
| `fc42b6a1` 1d | 共享 assistant / thinking 行 | -36 | +135 | +99 |
| `14f2433a` 1e | 共享 picker 弹层（模型/推理/审批/config） | -136 | +303 | +167 |
| 1f（slash 菜单） | 共享 slash 命令菜单 | -58 | +222 | +164 |
| 合计 | | **-829** | +1412 | +588 |

结论：**「抽取到共享 crate」在小组件上会净增 LOC**（共享模块含 spec/样式/文档，两侧
适配器仍存在）；Stage 1 的可验证收益是「同一行为只剩一份实现 + app 视图层缩减」，
而不是仓库总 LOC 下降。要真正净删，需要两类工作之一：
1. 继续把 app 视图层的大块（picker/slash/composer/审批卡）搬进 `agent_ui`——按当前
   比例估算，app 层可再减 ~500–700，总 LOC 大致持平或小幅下降；
2. Stage 2 统一会话模型后，删除一整条轨道的渲染/归约路径，才可能实现仓库级净删
   800+（这也是 Zed 用 `AcpThread` 收敛的真正收益）。
**口径决定（2026-10-25，产品确认）**：**仓库级「净删 800 行」不是硬性验收标准。**
Stage 1 验收 = **双栈共享组件单源 + app 视图层净删 ≥800（实测 -829）+ 门禁全绿与
文档/回归清单**；仓库级净删作为 Stage 2 的优化目标，不作为门槛（代码提交累计仓库总
LOC +597，继续抽取只会继续上升）。

#### Stage 1 收尾（2026-10-25）

**已单源到 `agent_ui`**：
| 模块 | 覆盖 |
|---|---|
| `message_flow` | 操作栏 gating、整回合复制、Scroll to User、底部兜底条 |
| `message_actions` | 操作栏与右键菜单渲染（id/aria/tooltip/hover 规则） |
| `markdown_view` / `safe_markdown` | Markdown 视图（可选中、代码块 Copy）与安全净化 |
| `markdown_text` | Markdown→纯文本 |
| `message_row` | assistant / thinking 行渲染 |
| `picker` | 模型 / 推理强度 / 审批模式 / ACP config 选择器弹层 |
| `command_menu` | slash 命令菜单 |

**实测**：app 视图层 **-829**，代码提交累计仓库总 LOC +597。
**验收口径（2026-10-25 产品确认）**：仓库 LOC 不是硬标准；以「双栈共享组件单源 +
app 视图层净删 + 全部门禁/文档」为 Stage 1 验收，仓库级净删留作 Stage 2 优化项。

**未抽 composer（有意为之）**：两栈 composer 的能力面（native：附件/queue/steer/plan/
checkpoint/审批模式/mention chip/自定义 placeholder；ACP：config pickers/安装引导）差异
远大于共享骨架，抽「输入卡 + footer」只能省 ~30 行却要引入大量 slot 与回调，且 keyboard/
focus 语义容易回归。建议并入 Stage 2（统一会话模型后 composer 只保留一份能力渲染）。

**真机回归执行状态（2026-10-25）**：按上述清单在真机 macOS 跑过 native 面板（隔离实例 +
EchoProvider / 种子 Fake Provider），操作栏、整回合复制、模型/推理/审批 picker、slash 菜单
均通过；ACP 链路因隔离实例无真实登录与外部 agent 未执行。完整结果与截图见
[2026-10-25-stage1-gui-regression.md](2026-10-25-stage1-gui-regression.md)。

**真机回归清单（人工补测项见上）**：
1. native：消息操作栏（回合末/streaming 历史可见/底部隐藏）、整回合 Copy、thinking chevron、
   assistant 行间距、picker（模型/推理/审批）滚动与选中、slash 菜单 hover 选中与 detail。
2. ACP：同一组操作栏行为、config picker 搜索/滚动条、slash 菜单选中底色、Markdown 代码块
   Copy（新增能力）、消息区滚动三按钮（track_scroll 修复后）。
3. 双栈：`Scroll to Top` 仅底部、末尾停在工具卡时的兜底条、等审批时底部条隐藏。

### Stage 2：统一会话模型 + 单 UI（1–2 周，核心）

- 把 `agent_ui`（现 31 行桩）做成真正的共享 UI/视图层：先承载 `message_flow`、消息流渲染与
  composer，再引入 `ConversationThread{entries, permission_requests, submissions, usage,
  checkpoint, capabilities}` + 单 reducer + 按条目索引事件 + `Connection` trait（能力方法）；
  会话模型先放同一 crate，出现第二个消费者或独立依赖面时再裂出 model crate（对齐 Zed 的
  `agent_ui` / `acp_thread` 分法，但不为拆而拆）。
- 两个 ingestion 入口：ACP 把 `HostEvent`/协议 update 映射进来（**先补 ACP 事件**：
  工具 args/输出/状态、用量、plan/compaction——这同时修掉 ACP 工具卡信息量不足的历史债）；
  native 直接调用 typed API（无序列化）。
- UI 只读共享模型；`native_agent_view.rs` 收缩为 adapter；app 回到组合根。
- 能力位承接差异：checkpoint restore（truncate）、steer/queue、subagent、model config options。
- 验收：reducer 黄金测试（ACP fixture 与 native fixture 产出相同结构）；两轨 e2e；
  删除 `ChatEntry`/`HostState` 的渲染路径。

### Stage 3：能力收敛与长期判断

- 统一审批模型（`ApprovalRequest{id,tool,args}` + `Once/Session/Pattern/Deny`；ACP 的
  allow/deny 降级为 Once/Deny）；统一标题/历史/摘要/i18n；native 补 MCP/lease（或明确不做并写进 ADR）。
- 决策点：**双轨是长期形态还是过渡**？Zed 证明双轨可以长期存在（native 默认 + external 高级），
  前提是收敛在模型层；若产品决定最终单轨，再谈删除 ACP 或 native（Zed 没删，我们也没必要先删）。
- 明确不合并：provider/tools/sandbox/checkpoint 存储、MCP/registry、native 的 queue/steer/subagent。

### 验收与度量

- 单测：reducer 对两路输入的黄金快照；copy/scroll/turn-end 判定的变异验证（AGENTS.md 要求）。
- e2e：native + 至少一个外部 ACP agent 各跑一次真实会话；截图/录屏留在 epic 回归。
- 度量：重复实现行数、UI 文件行数、事件契约数量（2→1）、native/ACP 行为差异清单长度。

---

## 6. 决策与开放问题

> 2026-10-25 讨论后更新：Q1/Q2/Q3/Q4/Q5 均已拍板（见下）。

1. **【已定｜产品】双轨是长期形态，不是过渡。** 与 Zed 一致：native 默认 + external ACP 高级模式；
   投入 Stage 2 收敛成「一套 UI + 一个客户端会话模型」；**不做 transcript 迁移**；
   Stage 2 之后按真实使用数据 review 是否调整 external 的定位。
2. **【已定｜抄 Zed】Copy This Agent Response = 该回合完整 agent 回复**（上一用户消息之后、
   下一用户消息之前的所有 assistant 正文，跳过 thinking）；右键 `Copy` / `Copy as Markdown`
   仍是单块内容。Stage 0 已按此实现，两栈一致。
3. **【已定｜不做】ACP checkpoint。** Zed 的 checkpoint/编辑重发/restore 全由 `can_rewind_to`
   门控，要求 `connection.truncate()`；该能力只有 native 实现（ACP v1/v2 均无，协议也没有
   rewind 方法）。因此外部 ACP agent 在 Zed 里同样没有 checkpoint → 我们保持 native-only，
   等 ACP 协议出现 rewind 能力再评估。
4. **【已定｜2026-10-25 产品确认】MCP = 客户端资产，两个 runtime 都消费。** 抄 Zed 的形态
   （Stdio/Http 配置形状 + 客户端唯一 registry + 按 session 下发/注入）；**v1 配置来源只有平台
   租赁**（`learning_host` 的 CGC MCP，5 个学习工具，session 级不落盘），**不开放用户自定义
   MCP server**；用户可编辑的 `context_servers` 留作后续高级模式开口（受 ADR-0026 签名清单/
   白名单与 ADR-0021 scopes 约束）。native MCP client 与「native 在课程页转默认」同批（P1b）交付。
5. **【已定｜已执行】`agent_chat` 改名为 `agent_ui`**（2026-10-25，对齐 Zed 命名）；
   crates/package/模块引用已改，路由 id 与 i18n key（`agent_chat.panel*`）暂留作页面标识。
   Stage 1 先搬共享消息流渲染/composer 进去，Stage 2 再搬会话模型；暂不拆独立 model crate。

---

## 附录 A：Zed 关键文件索引

| 主题 | 位置 |
|---|---|
| AgentServer trait | `crates/agent_servers/src/agent_servers.rs:51` |
| AgentConnection trait / 能力方法 | `crates/acp_thread/src/connection.rs:95`；能力 `:117/134/156/175/180/196/258/347/543` |
| AcpThread 状态 | `crates/acp_thread/src/acp_thread.rs:3529` |
| 单 reducer | `crates/acp_thread/src/acp_thread.rs:4739 handle_session_update` |
| 事件枚举 | `crates/acp_thread/src/acp_thread.rs:3698 AcpThreadEvent` |
| 流式缓释 | `acp_thread.rs:3635-3660`、`:5561-5590` |
| 提交三态 | `crates/acp_thread/src/submission.rs:164` |
| checkpoint / rewind | `acp_thread.rs:7593 restore_checkpoint`、`:7626 rewind`、`:4173 can_rewind_to` |
| native 实现 | `crates/agent/src/native_agent_server.rs:23`、`agent.rs:3269 NativeAgentConnection`、`:3584 AgentSessionTruncate` |
| native 镜像桥 | `crates/agent/src/agent.rs:2765+`、`thread.rs:1288 Thread` |
| UI 单实例 | `crates/agent_ui/src/conversation_view.rs:1729` |
| 消息操作栏 | `crates/agent_ui/src/conversation_view/thread_view.rs:7703`、`:7912`、`:7933`、`:8742`、`:8855` |
| 单元增量更新 | `crates/agent_ui/src/conversation_view.rs:2002` |
| 持久化所有权 | `crates/agent_ui/src/thread_metadata_store.rs:309`、`crates/agent/src/thread_store.rs:12` |
| 工厂 | `crates/agent_ui/src/agent_ui.rs:579` |
| ACP 单前台 dispatch | `crates/agent_servers/src/acp/runtime.rs:26`；暂存 `session_updates.rs:9,153` |
| 版本回退 | `crates/agent_servers/src/acp.rs:123-165` |

## 附录 B：我们重复项清单

见 §3 表（14 项，逐项 file:line 与行数）。补充：`crates/app/src/native_agent_view.rs:4837
message_action_button`（native）vs `chat/panel.rs:1256 chat_action_button`（ACP）；
`native_agent_view.rs:4826 previous_user_message_index` vs `controller.rs:3889 previous_user_chat_index`
（两份纯函数 + 两份单测）。

## 附录 C：方法与限制

- Zed 侧：本地源码 `347f171a` 为主，xerj 索引 `myref-docs`（2026-10-19 快照）用于检索定位；
  两者版本差 5 天，涉及时效结论均已回源码复核。
- 我们侧：静态阅读 + `git log/show`；未跑 GUI、未做真机并排验收，行数为 `wc -l` 或函数边界估算。
- 三路独立取证（Zed 架构 / Zed UX / 本仓审计）交叉核对；关键结论（ThreadView 单实例、
  AgentConnection 三实现、#61245/#61362 最终 gating、两处操作栏 gating、ADR 偏差）已由 Lead 复核。
