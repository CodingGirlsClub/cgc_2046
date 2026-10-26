# Stage 3.6 Phase B 计划：共享视图收口 + 删除 native_agent_view

- 状态：计划（2026-10-26）
- 依据：`docs/plans/2026-10-26-1000-stage3-capability-convergence-design.md` §4 Phase B / 3.6
- 前置：3.1（native-as-ACP）、3.2（权限卡/规则）、3.3（transcript/历史/标题）已完成；3.5a（全局 Agent Panel + 课程上下文）已完成
- 不依赖：3.4 native MCP client、3.5b 默认 native（MCP 暂缓期间可独立推进）
- 验收（设计 §4）：两轨同一 thread view；附件/queue/steer/checkpoint 以 capability 迁入共享视图；删除 `native_agent_view.rs`（记录净删行数）；两轨真机回归

## 1. 现状盘点（2026-10-26）

| 文件 | 行数 | 说明 |
|---|---|---|
| `desktop/crates/app/src/native_agent_view.rs` | 5901 | native 专属面板（header/composer/queue/attachments/checkpoint/subagent/model picker/审批） |
| `desktop/crates/app/src/native_thread_state.rs` | 635 | native aux 状态（pending permission/subagents/error） |
| `desktop/crates/app/src/root_view/screens/chat/panel.rs` | 1238 | ACP/共享聊天面板（消费 `ConversationThread` + `ChatUi`） |
| `desktop/crates/app/src/root_view/screens/chat/agent_panel.rs` | 496 | Agent Panel 壳（header / `＋` 菜单 / native-ACP 分流） |
| `desktop/crates/agent_ui/src/{message_row,message_flow,message_actions,permission_card}.rs` | 135/183/约 550 | 已共享的消息行/操作栏/审批卡 |

已共享（3.1–3.5 完成）：事件 ingestion（`agent_ingest`）、`ConversationThread`、审批卡、消息行/操作栏、标题、历史、账本式 session 存储、Agent Panel 壳与全局入口、课程页上下文。

native 仍独占的能力（Phase B 待迁移）：附件/图片（clipboard/picker/@mention/skills chip）、queue/follow-up、steer、checkpoint（列表/恢复/逐文件 Keep-Reject）、subagent 行/进度、模型/thinking/approval-mode 选择器、workspace 规则 prompt（system prompt 构造）。

## 2. 目标形态

单一共享视图：两轨都只向 `ConversationThread` + `ThreadCapabilities` + 一个 `ChatSurface`（composer/action 回调集合）供数，UI 只读模型与能力位。

```
native runtime ─┐
                ├─ agent_ingest → ConversationThread ─→ shared chat panel
ACP connection ─┘        ↑
             NativeRuntimeAdapter / AcpRuntimeAdapter（能力回调：attach/queue/steer/checkpoint/picker）
```

`ThreadCapabilities` 决定 UI 入口显隐：native 可开 checkpoint/subagent/queue/steer/附件；ACP 按协议能力（`agent-client-protocol` 通知/请求）决定。

## 3. 分片（每片独立 commit + 门禁）

### B1（0.5–1d）共享视图 seam（不删代码）
- 在 app 定义 `ChatSurface`（或等价）承载 composer/action 回调：attach、queue/steer、checkpoint、subagent、model/thinking picker、approval mode。
- `render_chat_panel` 改为只依赖该 surface + `ConversationThread`/capabilities（当前依赖 `ScreenContext`/`ChatUi`）。
- native 面板挂在 `CGC_NATIVE_SHARED_VIEW=1` 后面用共享面板渲染 body（保留旧 native 面板作回退）。
- 验收：开关下 native 消息/审批/复制/滚动与 ACP 一致；单测（capability→入口显隐矩阵）。

### B2（1–2d）composer 能力迁移
- 附件/图片、@mention/skills chip、queue/follow-up、steer 迁入共享 composer（native adapter 供数；ACP 按能力）。
- native 旧 composer 删除；queue/steer 语义测试（排队顺序、取消、失败重发）。
- 验收：native 图片/附件/技能/mention 与旧行为等价；两轨输入框视觉一致。

### B3（1–2d）checkpoint / subagent / 模型选择器
- checkpoint 列表/恢复/Keep-Reject、subagent 行进共享视图（capability gated）。
- native 模型/thinking/approval-mode 选择器并入共享 header/config picker 区（或作为 native capability 的 header 片段）。
- 验收：checkpoint 恢复/逐文件 Keep-Reject 测试；subagent 进度行；模型切换即时生效。

### B4（1d）删除 native_agent_view.rs
- 删除 5901 行文件与只被它使用的 helper（`native_thread_state` 保留必要部分或并入 app 状态）；记录 `git diff --stat` 净删行数。
- 清理旧开关/死代码；`agent_panel.rs` native 分支只走共享面板。
- 验收：workspace 门禁绿；净删行数报告；无 clippy `-D warnings` 告警。

### B5（1d）两轨真机回归 + 文档
- native/ACP 真机回归：消息/附件/审批/copy/checkpoint/queue/steer/模型/标题/历史/侧栏。
- 设计文档补 §13 Phase B 记录；README/ADR-0028 更新「共享视图」状态；Phase B 开关移除。

## 4. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 状态所有权（`NativeThreadState` vs `ChatUi`）迁移期间双份状态不一致 | B1 先做单向 adapter（native→共享模型），旧面板回退；每片对比两轨测试 |
| 事件 ingestion 重复/顺序（native 进程内 ACP + 旧视图路径） | 保留 `agent_ingest` 单一入口；native 旧事件路径仅 UI 回退用 |
| queue/steer 语义与 ACP 协议能力不一致 | capability 位显式 gating；native 优先迁移，ACP 待协议支持再开 |
| checkpoint 与 ACP 无对应能力 | capability `checkpoint_restore=false` 的轨不显示入口；不硬塞 |
| 5901 行删除引发回归 | B4 前 B1–B3 全覆盖；逐能力单测 + 真机回归；删除后只保留净删行数报告 |
| 与 3.5b/MCP 并行冲突 | Phase B 不依赖 MCP；3.5b 待 MCP 恢复后单独切片，不阻塞 B1–B4 |

## 5. 首个可提交切片（B1 建议实现顺序）

1. 抽 `ChatSurface` trait/struct + capability→入口显隐纯函数 + 单测（新文件 `app/src/root_view/screens/chat/surface.rs`）。
2. `panel.rs` 改为由 surface 驱动 composer/操作栏（ACP surface 先行，行为不变；门禁绿）。
3. native 面板新增 feature flag 下的共享 body 渲染 adapter（只读 `NativeThreadState.thread` + capabilities 映射），旧 native 面板保留。
4. commit：`refactor(chat): 抽出共享 ChatSurface（Phase B1）`。
