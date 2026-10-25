# Stage 2 设计：统一会话模型 + 单 UI

> 状态：**设计草案（待评审）** · 2026-10-25
> 关联：[ADR-0028](../adr/0028-desktop-native-agent-dual-track.md)（双轨形态）、
> [Zed agent 架构参考](2026-10-25-1305-zed-agent-architecture-reference.md) §5 Stage 2、
> [Stage 1 收尾与真机回归](2026-10-25-stage1-gui-regression.md)。
> 目标：模型层收敛，两轨共享同一套会话模型与 UI；运行时保持分离；最终删掉一条重复渲染路径。

## 0. 结论先行

- 统一的是**客户端会话模型 + UI**，不是运行时。provider/tools/sandbox/checkpoint 存储、
  MCP/registry、native 的 queue/steer/subagent 仍归各自轨道（ADR-0028 决策 2/6）。
- 模型先放 `agent_ui`（同 crate 加 module），出现第二个消费者或独立依赖面再裂出 model crate。
- **2a 先补 ACP 事件面**：当前 `HostEvent::ToolCall { title, kind }` 丢掉了工具 id/status/
  args/output、usage、plan、compaction，既是统一模型的阻塞项，也是 ACP 工具卡信息量不足的历史债。
  2a 独立可合，不依赖模型统一。
- 迁移按切片推进（2a→2f），每片可回滚；不做 big-bang 重写。

## 1. 前提假设（请评审时确认/纠正）

1. 双轨长期存在：native 默认学习 agent，external ACP 保留高级模式；不删任一侧运行时。
2. external ACP agent 的协议能力参差：`SessionUpdate` 子集不一定全发；模型必须允许字段缺失
   并用能力位表达差异，未知/不支持的 update 安全忽略。
3. native `AgentEvent`（`agent_host/src/events.rs`）字段是超集，可作为目标模型的信息上限；
   ACP 侧能映射多少就展示多少，缺失即降级（`Option` / 空列表 / capability=false）。
4. 本阶段**不改持久化格式**（`chat_state.json`、agent store、ACP session 文件保持兼容）；
   模型是内存态，重放/恢复由各轨道 ingestion 适配。
5. 2a 不改 UI 信息架构：只让现有工具卡能显示 status/args/output(折叠) 与 usage；plan/compaction
   先进入模型/事件，UI 展示留到 2c/2e。

## 2. 目标架构

```
ACP agent process ──HostEvent──▶ AcpIngest ──┐
                                             ├─▶ ThreadEvent ─▶ ConversationThread::apply
native agent host ─AgentEvent──▶ NativeIngest┘                       │
                                                                     ├─ entries / status / usage / plan
                                                                     ├─ capabilities / checkpoint / configs
                                                                     └─ pending permission / submissions
                                                                           │
                     agent_ui::conversation_view ◀── 只读模型 ────────────┘
                           │
                     callbacks（prompt/cancel/permission/config/checkpoint）→ ThreadConnection trait
```

### 2.1 `ConversationThread`

```rust
pub struct ConversationThread {
    pub thread_id: ThreadId,
    pub title: Option<String>,
    pub updated_at: Option<String>,
    pub entries: Vec<Entry>,
    pub status: ThreadStatus,                 // Idle / Generating / AwaitingApproval / Failed
    pub capabilities: ThreadCapabilities,
    pub usage: Usage,                          // used, size, cost, last turn tokens
    pub plan: PlanState,                       // steps + updated_at
    pub checkpoint: Option<CheckpointInfo>,    // native only；ACP 恒 None
    pub pending_permission: Option<PermissionRequest>,
    pub submissions: Vec<Submission>,          // native queue/steer；ACP 空
    pub configs: Vec<ConfigOption>,
    pub commands: Vec<CommandView>,
}
```

### 2.2 `Entry`（渲染的原子行）

| Entry | 字段 | 来源 |
|---|---|---|
| `User` | id、text、mentions、images | ACP `send_prompt` 回显 / native `TurnStarted`(text) |
| `Assistant` | text、turn_id | `Delta*` 聚合 |
| `Thinking` | text、expanded | `ThoughtDelta` / `ThinkingDelta` |
| `ToolCall` | id、title、name、kind、status、args(JSON)、output(text/结构化)、locations、diffs、turn_id | ACP `ToolCall`/`ToolCallUpdate`；native `ToolCallStarted/Finished` |
| `Permission` | request_id、title、tool_call_id、args?、resolved: Option<bool> | ACP `RequestPermission` / native `PermissionRequested` |
| `Notice` | level(info/warn/error)、text | native `Error`、ACP `Error`/`Notice` |
| `Compaction` | status、summary | ACP `CompactionUpdate`；native `ContextCompacted` |

分组/turn 边界由 `turn_id` + `message_flow` 的既有判定共同决定：`RowView` 继续负责
「操作栏只在 finalized turn end / 底部兜底条」，模型只提供 turn 归属与 finalized 状态。

### 2.3 `ThreadEvent`（统一 reducer 输入）

```rust
pub enum ThreadEvent {
    ThreadLoaded { entries, capabilities, usage },
    TurnStarted { turn_id, user: UserInput },
    TextDelta(String),
    ThinkingDelta(String),
    ToolCallStarted { tool_call_id, title, name, kind, args },
    ToolCallUpdated { tool_call_id, patch: ToolPatch },   // status/content/output/locations
    ToolCallFinished { tool_call_id, ok, output },
    PermissionRequested { request_id, title, tool_call_id, args },
    PermissionResolved { request_id, allowed },
    PlanUpdated { steps },
    UsageUpdated { used, size, cost },
    ConfigOptionsUpdated { options },
    CommandsUpdated { commands },
    Notice { level, text },
    CompactionUpdated { status, summary },
    TurnFinished { stop_reason, cancelled },
    Exited,
}
```

reducer 规则：
1. 流式文本按 entry 聚合，工具卡前先 flush（沿用 Stage 1 的 `flush_streaming` 语义）。
2. `ToolCallUpdated` 按 `tool_call_id` 合并；缺失 id 时降级新建 entry（兼容旧 agent）。
3. `PermissionResolved` 只改对应 entry 的 `resolved`，不删除行。
4. `PlanUpdated` 整体替换（协议语义：每次全量）。
5. 未识别事件/未知字段忽略，不 panic；错误进 `Notice(level=error)`。

### 2.4 能力位

| Capability | native | external ACP | UI 影响 |
|---|---|---|---|
| `checkpoint_restore` | true（Git） | false | 编辑/恢复按钮、truncate 菜单按位隐藏 |
| `steer` / `queue` | true | false | composer steer/queue 入口按位隐藏 |
| `subagent` | true | false | 子卡渲染按位 |
| `config_options` | true（模型/推理/审批） | 取决于 session config | 选择器按位 |
| `plan` | true | 协议 v1 Plan（若 agent 发送） | plan 卡按位 |
| `usage` | true | UsageUpdate（若发送） | footer 用量按位 |

### 2.5 UI 与 connection

- `agent_ui::conversation_view`：只读 `&ConversationThread` + `ConversationStyle` + callbacks；
  行渲染继续复用 `message_row` / `message_actions` / `markdown_view`。
- `ThreadConnection` trait（UI 依赖它，不依赖具体运行时）：

```rust
trait ThreadConnection {
    fn prompt(&mut self, input: UserInput);
    fn cancel(&mut self);
    fn respond_permission(&mut self, request_id: &str, decision: PermissionDecision);
    fn set_config(&mut self, config_id: &str, value: &str);
    fn restore_checkpoint(&mut self, checkpoint: &CheckpointInfo);
    fn load_history(&mut self);
}
```

实现：`AcpThreadConnection`（包 `AcpHost`）与 `NativeThreadConnection`（包 `agent_host` 句柄）。
第一版 trait 只需 UI 用到的 6 个方法，不预设计更多。

## 3. 事件映射

### 3.1 ACP：现状缺口（2a 要补的部分）

| ACP `SessionUpdate` | 现状 | 2a 目标 | 关键字段 |
|---|---|---|---|
| `AgentMessageChunk` | ✅ Delta | 不变 | text |
| `AgentThoughtChunk` | ✅ ThoughtDelta | 不变 | text |
| `AvailableCommandsUpdate` | ✅ commands | 不变 | commands |
| `ToolCall` | ⚠️ 仅 title/kind | `ToolCallStarted` | `tool_call_id`、`title`、`name`、`kind`、`status`、`content`（Text/Diff/Terminal）、`locations`、`raw_input`(→args) |
| `ToolCallUpdate` | ❌ 忽略 | `ToolCallUpdated` / `ToolCallFinished` | `tool_call_id`、`fields.{title,name,kind,status,content,raw_output,locations}` |
| `Plan` | ❌ 忽略 | `PlanUpdated` | `entries[{content,priority,status}]` |
| `UsageUpdate` | ❌ 忽略 | `UsageUpdated` | `used`、`size`、`cost` |
| `ConfigOptionUpdate` | ❌ 忽略 | `ConfigOptions`（已有事件） | `config_options` |
| `CurrentModeUpdate` | ❌ 忽略 | `ModeUpdated`（可并入 Config/能力） | `current_mode_id` |
| `SessionInfoUpdate` | ❌ 忽略 | `TitleUpdated` | `title`、`updated_at` |
| `CompactionUpdate` / `CompactionSummaryChunk` | ❌ 忽略 | `CompactionUpdated`（可选先只记 Notice） | `compaction_id`、`status`、`summary`、`error` |
| `RequestPermission`（request，不是 update） | ⚠️ 仅 title | `PermissionRequested` 增加 `tool_call_id`/`args` | `tool_call` 的 id/title/输入 |
| `UserMessageChunk` / `v2 UserMessage` | ❌ 忽略 | 2b 接入（重放/回显） | id、content |

实现要点：
- `HostEvent` 是 `platform → app` 的内部契约，没有外部消费者（仅 `root_view::controller.rs`
  与 `platform/examples/mcp_injection.rs`），可直接改，不需要兼容层。
- `ToolCallStatus` / `ToolKind` / `PlanEntryStatus` 用稳定小写字符串转成 view 字段，
  UI 不依赖协议 crate 类型（保持 `platform` 边界）。
- `ToolCallContent` 的 `Text` 拼成 output；`Diff` 保留 path/旧新文本用于折叠展示；
  `Terminal` 只保留 terminal id/标题；未知变体忽略。
- args 可能包含敏感内容：只存内存、默认折叠、不写日志/遥测/崩溃报告（AD-13/AD-16）。

### 3.2 native：映射到同一 `ThreadEvent`

| native `AgentEvent` | ThreadEvent |
|---|---|
| `TurnStarted` | `TurnStarted`（user 输入来自 `FollowUpStarted`/`SteerStarted` 的 text） |
| `TextDelta` / `ThinkingDelta` | 同名 |
| `ToolCallStarted {id,name,args}` | `ToolCallStarted` |
| `ToolCallFinished {id,ok,content}` | `ToolCallFinished` |
| `PermissionRequested {tool_call_id,name,args}` | `PermissionRequested`（title 用 name） |
| `UsageUpdated {usage,total}` | `UsageUpdated`（映射到 used/size；last turn 另存） |
| `ContextCompacted` | `CompactionUpdated`（native 只有计数，summary 空） |
| `Subagent*` | `Entry::Notice`/子卡（能力位 subagent） |
| `TurnFinished` | `TurnFinished` |

native 没有 `Plan` 事件：plan 由 native 的工具（`todo_write`/plan step 工具）或 UI 状态提供，
2b 决定是否把 `plan_state` 纳入模型（见开放问题）。

## 4. 2a 实现范围（本阶段可合）

1. `platform/src/acp/connection.rs`：扩展 `HostEvent`（新增字段/变体）+ 协议映射；单元测试用
   `SessionNotification` 构造各 update（fixture JSON/结构体），断言映射结果。
2. `app/src/root_view/controller.rs`：消费新事件并维护现有 `ChatEntry`：
   - `ChatEntry::Tool` 增加 `id/title/kind/status/args/output`；`ToolCallUpdate` 按 id 合并；
   - `ChatEntry::Permission` 增加 `tool_call_id`/args 展示（可选）；
   - usage 更新到 `ChatUi`（footer 已有 `0% · 0/64k` 展示，接 used/size）；
   - plan/compaction 先不渲染，留事件/字段（或最小 Notice 行）。
3. UI：ACP 工具卡增加状态 chip + args/output 折叠区（复用 `message_actions` 的复制/展开风格）；
   usage footer 接真实数据。保持现状的是：授权按钮、config picker、slash 菜单、操作栏不变。
4. 测试：协议映射单测；controller 合并/顺序单测；工具卡渲染的快照或元素断言；
   关键守卫（turn-end/bottom/copy）不回归。变异验证：改坏 `ToolCallUpdated` 合并
   或 `usage` 更新，断言必须红。

验收：
- fake ACP agent 发 tool call + update + usage 时，UI 工具卡显示 running/done、args/output 可展开、
  footer 用量更新；无 args/output 的旧 agent 行为不变。
- `cargo fmt --check` / `clippy -D warnings` / `cargo test --workspace --exclude cgc-agent-tools` 绿。
- 真机：用现有 external agent 跑一次（需已登录实例；可与原生 ACP 回归合并做）。

### 2a 实现状态（2026-10-25，已落地）

- `platform/acp/connection.rs`：`HostEvent` 扩展为 `ToolCallView`（id/title/name/kind/status/
  args/output/locations）、`ToolCallUpdated`、`PlanUpdated`、`UsageUpdated`、`TitleUpdated`、
  `ModeUpdated`、`CompactionUpdated`，`PermissionRequested` 增加 `tool_call_id`/`args`；
  `host_event_from_update` 统一映射 `SessionUpdate`（ToolCall/ToolCallUpdate/Plan/Usage/
  ConfigOption/CurrentMode/SessionInfo/Compaction），未知变体忽略。
- `app`：`ChatEntry::Tool` 扩展并按 `tool_call_id` 合并（`merge_tool_update`，update 先到时
  补最小卡）；ACP 工具卡显示状态 chip + 参数/输出折叠（截断上限 600/1200 字符）；composer
  footer 显示真实 context 用量；`TitleUpdated` 映射到已有 `title_override`；本地 thread
  持久化的 `Entry::ToolResult` 保真（id/name/content/is_error）。
- **延后**：plan/compaction 的 UI 呈现（事件已带上来，controller 先 no-op，留 2c/2e）；
  permission 的 args 展示与 mode UI 同批。
- 验证：platform 新增 5 个映射单测；app 新增 3 个合并单测；两处关键守卫做变异验证
  （改坏状态合并/状态映射 → 测试红，还原 → 绿）。workspace 测试通过（`registry` fetch
  用例为已知并行超时 flake，单独重跑通过）。真机 ACP 回归仍需已登录实例（与人共做）。

### 2b 实现状态（2026-10-25，已落地）

- `agent_ui::conversation` 从 doc 桩变成共享模型：`ConversationThread`（thread_id/title/
  entries/status/capabilities/usage/plan/checkpoint/pending_permission）、`Entry`（User/
  Assistant/Thinking/ToolCall/Permission/Notice/Compaction）、`ThreadEvent`（协议无关）、
  统一 reducer `apply`、能力位 `ThreadCapabilities::native()/acp()`。
- reducer 规则：文本/思考增量聚合；工具卡后到来的文本开新 assistant entry（修掉 ACP
  之前工具后文本被丢弃的路径）；工具更新按 id 合并、未知 id 忽略；审批置
  `AwaitingApproval` 并要求显式 resolved；回合结束折叠 thinking/清 pending；失败转
  `Failed + Notice(Error)`。
- `ConversationThread::row_view()` 直接复用 `message_flow` 的 turn-end/复制/滚动判定。
- 验证：7 个 reducer 单测（含「native 与 ACP 事件序列产出相同 entries」黄金测试、
  工具后文本、工具合并、审批、回合结束/失败、loaded、row_view 契约）；变异验证
  两处（工具状态合并、工具后文本开新 entry）→ 对应测试红，还原后绿。

### 2c 实现状态（2026-10-25，已落地）

- `RootView::ChatUi.messages` 换成 `ConversationThread`；controller 把 `HostEvent`
  映射成 `ThreadEvent` 交给统一 reducer，`ChatEntry`、`chat_row_view`、
  `merge_tool_update`、`streaming_message_open` 全部删除；审批 `resolved` 由
  `PermissionResolved` 维护；本地线程持久化改为遍历模型 entries 映射。
- ACP 面板行渲染读 `thread.entries`，操作栏/整回合复制/滚动 gating 改用
  `thread.row_view()`；新增 Notice/Compaction 状态行；usage footer 读
  `thread.usage`；`has_unresolved_permission` 改用模型 Entry。
- 行为改善：工具卡之后到达的文本会开新 assistant entry（此前 ACP 可能丢文本）。
- 验证：app 117 + agent_ui 29 测试绿；fmt/clippy 干净；`registry::discovery` 的
  HTTP fetch 用例为本机并行超时 flake（串行重跑通过）；app 文件净 -156 行。

### 2d 进行中（2026-10-25）

- **模型 crate 拆分**：`cgc-agent-conversation`（gpui-free）= `conversation` +
  `message_flow`；`agent_ui` re-export 保持下游路径不变。
- **native ingestion 下沉**：`agent_host::HostState` 依赖模型 crate，新增
  `thread: ConversationThread` / `context_size` 并在 `apply(AgentEvent)` 里映射
  到 `ThreadEvent`（文本/思考/工具/审批/usage/压缩/错误/结束）；`app` 侧临时的
  `native_conversation` adapter 删除，改由 host 单点负责。
- 持久化线程投影进模型：`apply_thread_entries` 在重建 `HostState` 时同步填充
  `state.thread.entries`（User/Assistant/Thinking/ToolResult/Compaction），并写入
  thread_id、usage（used/size）与 context window；native 发送路径同步把 user
  消息 apply 进模型。
- **视图已改读模型**：native 渲染的 `state.messages` 现在由
  `project_thread_to_messages(thread)` 每帧从模型投影（1:1 保序），删除流式
  thinking/streaming 两行（模型 entries 本身实时更新）、`live_thinking_collapsed`
  与自动展开转移逻辑；系统提示统一走 `HostState::push_notice` 同时进模型 Notice；
  审批解决同步 `PermissionResolved`；不吐流式增量的 provider 在 TurnFinished 补
  TextDelta 兜底。渲染函数签名仍是旧行类型（下一片切 `ConversationEntry`）。
- 过渡期 `HostState` 仍保留 `messages/streaming` 字段（`messages` 已退化为投影缓存）；
  下一步：渲染函数切 `ConversationEntry`，删除 projection 与旧字段/`UiMessage`。

- 验证：agent_host 15 个 reducer/事件测试（含新增 thread 断言）、模型 18 个、
  app 125 个全绿；fmt/clippy 干净。

## 5. 切片与回滚

| 切片 | 内容 | 写入面 | 验收 | 回滚 |
|---|---|---|---|---|
| **2a** | ACP 富事件 + 最小 UI 呈现 | `platform/acp/connection.rs`、`root_view.rs/controller.rs`、共享行/卡 | 上述 2a | revert 单 commit；事件是内部契约 |
| 2b | `ConversationThread` + reducer + golden（native fixture 先行） | `agent_ui/conversation/*` | reducer 快照 & 变异 | 纯新增模块，可整体 revert |
| 2c | ACP 面板切模型；删 `ChatEntry` 渲染路径 | `root_view`、`agent_ui/conversation_view` | 两轨 ACP e2e；行数下降 | 保留 `ChatEntry` 到 2c 验收后删；revert 切片 |
| 2d | native 视图切模型；删 `UiMessage` 渲染路径 | `native_agent_view.rs`、`agent_ui/conversation_view` | native e2e + 真机回归 | 同上 |
| 2e | composer 单一实现 + 能力位 | `agent_ui/composer`、两 adapter | 真机回归清单 | revert 切片 |
| 2f | 验收/度量/回归 | 文档 + 测试 | 指标达标 | — |

每片一个本地 commit（或小 PR）；不 push（按本会话约定）；合并前需要人处理
`desktop/Cargo.lock`、`desktop/AGENTS.md`、ADR 文档等人工合并范围。

## 6. 验收与度量

- **reducer 黄金测试**：同一会话分别用 ACP fixture 与 native fixture 喂入，产出的
  `Vec<Entry>`/status/usage 结构一致（允许能力位差异）。
- **行为回归**：`message_flow` 的 turn-end/bottom/copy 判定迁移到模型后，变异验证仍需通过。
- **e2e**：native + 至少一个 external ACP agent 各跑一次真实会话（截图/录屏留档）。
- **度量**（对照 Stage 1：app -829 / 仓库 +597）：
  - 删除的重复渲染路径行数（目标：仓库级净删转负）；
  - `native_agent_view.rs` / `root_view` 行数；
  - 事件契约数量（当前 ACP/native 两套 → 模型 1 套）；
  - 两轨行为差异清单长度（目标只余能力位差异）。

## 7. 风险与回滚

1. **ACP agent 差异**：旧 agent 不发 `ToolCallUpdate`/`UsageUpdate`；模型字段必须 `Option`/默认，
   能力位 = false，UI 降级。未知 `SessionUpdate` 继续 `_ => {}`，不 panic。
2. **协议版本**：当前接 v1；v2 的 `ToolCallChunk`/`StateUpdate` 等不阻塞 2a，后续按 agent 能力扩展。
3. **参数隐私**：tool args/output 可能含用户数据；默认折叠、不写日志/遥测；沿用 AD-13/AD-16。
4. **大改风险**：2c/2d 切换 UI 前必须有 golden + e2e；切片可独立 revert。
5. **持久化**：2a 只改内存态；若后续把模型快照写盘，需另开兼容/迁移设计（本阶段不做）。

## 8. 开放问题（2b 前定）

1. Plan 放 `Entry::Plan`（inline 卡片，Zed 风格）还是 `thread.plan` 单独区域（native 现有 plan card）？
   → 建议：模型层 `thread.plan`（协议语义是整体替换）+ UI 两种呈现，但渲染单源。
2. queue/steer/subagent 的 UI 是模型 entry 还是 composer 附属区？→ 2e 再定，2b 只留字段。
3. compaction 在 UI 上是折叠行、Notice 还是顶部 banner？→ 2c 真机看 external agent 行为再定。
4. ACP `HostEvent` 是否保留 `ToolCall {title, kind}` 变体作为兼容？→ 不保留；内部契约直接替换。
5. 是否把 `ConversationThread` 裂成独立 crate？→ 等第二个消费者（全局助手/CLI）出现，不在本阶段。
