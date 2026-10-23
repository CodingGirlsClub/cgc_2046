---
title: "Native Agent Message Editor 对齐 Zed 的改进建议"
type: plan
date: 2026-10-23
topic: desktop-native-agent
status: in-progress
---

# Native Agent Message Editor 对齐 Zed 的改进建议

> 背景：用户指出 native agent 的 message editor 与 ACP agent 面板差别很大。
> 本文基于 xerj 索引里的 Zed agent/UI 切片 + 本地 Zed 源码核对，给出差距清单与分阶段改进方案。
> 结论先行：**我们的 native composer 既不像 Zed，也不像自家 ACP 面板**；先把 composer 收敛成「单一卡片 + footer 控件组」，再补 slash/@ 上下文、队列与结构化卡片。

## 1. 调研方法与证据

- xerj 索引：`xc-zed-agent-b1792447736-zed-agent-slice-docs`（`agent_ui` 切片）、`xc-zed-ui-b1792446701-zed-ui-slice-docs`（`ui` 切片）；用符号/语义检索定位 composer 相关函数。
- 本地源码核对：`/tmp/cgc-agent-research/zed-all`（Zed 全仓快照）。
  - `crates/agent_ui/src/conversation_view/thread_view.rs`
    - `render_message_editor` (L5309)、`render_send_button` (L6446)、`render_thinking_control` (L6161)、`render_effort_selector` (L6280)、`render_add_context_button` (L6536)、`render_follow_toggle` (L6729)、`render_token_usage` (L5709)、`render_message_queue_entries` (L5515)、`render_plan_summary` (L4387)、`render_edits_summary` (L4725)、`render_generic_permissions` (L3980)
  - `crates/agent_ui/src/message_editor.rs`：`MessageEditor` 结构（L209，含 `MentionSet` + 真 `Editor`）与 `Render`（L2056）
  - `crates/agent_ui/src/completion_provider.rs`：`@` mention / `/` slash 解析与补全

## 2. Zed 的 composer 解剖

`render_message_editor` 的结构：

```
h_flex 居中（max_content_width）
  v_flex
    ├─ 上半：MessageEditor（真 Editor + MentionSet）
    │    ├─ @ 文件/目录/符号/诊断/终端选区/图片 mention（crease chip）
    │    ├─ / slash 命令补全（键盘导航）
    │    ├─ 图片粘贴/拖拽、附件预览
    │    └─ 右上角 Expand 按钮（Cmd+Shift+E）
    └─ 下半 footer（左右两组，自动换行）
         ├─ 左：Add Context "+"（Files & Directories / Symbols / Diagnostics /
         │        Terminal Selection / Images / Skills）、Follow toggle、
         │        Fast mode、Thinking toggle + Effort SplitButton
         └─ 右：activity status（Unconfirmed/Unknown）、discard draft、
                token usage（hover 分项）、profile selector、
                mode selector + model selector、Send 按钮
```

关键行为：

1. **发送按钮状态机**（`render_send_button` L6446）
   - 生成中 + 输入为空 → Stop（红色）
   - 生成中 + 有输入 → QueueMessage（排队，⌘↩ 立即发送）
   - 空闲 + 空输入 → Send（disabled，tooltip「Type to Send」）
2. **token usage** 在 footer（本会话/上下文占用/费用/缓存，hover 明细），不是顶部状态栏。
3. **thinking**：Thinking toggle（开/关）+ effort SplitButton（仅模型支持时显示；`render_thinking_control` L6161）。
4. **队列**（`render_message_queue_entries` L5515）：composer 上方列出 queued messages，每条可 steer、edit、remove；支持 clear queue。
5. **结构化卡片**：plan/todo summary（L4387）、edited files summary + Keep all/Reject all/Undo（L4725）、权限卡片（L3980：Allow once/Always/Pattern 粒度、Keep all/Reject all/Undo last）都渲染在消息流/composer 附近，不是 system 文本。
6. **键盘语义**：`MessageEditor` key context；Enter/Cmd+Enter 发送，Shift+Enter 换行，Chat / SendImmediately / Cancel 动作；composer 可展开编辑；queue 编辑。
7. **placeholder** 明确提示 `@ to include context, / for commands`。

## 3. 我们当前实现

### native agent（`native_agent_view.rs`）
- header：模型/usage/状态；
- 静态 slash 提示行（`native-agent-slash-hint`，无弹层、无键盘导航）；
- 消息列表、子 agent 卡片、审批卡（3 按钮）；
- composer 是两段式：toolbar 行（模型/推理/审批，L1329）+ textarea 行（发送/打断/变更/撤销，L1417），**不是单一卡片**；
- 无 @ 上下文、无队列 UI（follow-up 只显示状态文本）、token 在 header、plan/todo/edit summary 走 system 消息或独立面板。

### ACP 面板（`root_view/screens/chat/panel.rs`，可复用）
- 单一圆角 composer 卡片（L701，聚焦时 accent 边框）；
- footer：`+`（@ 入口）、Native 切换、config pickers、发送/停止图标按钮（L759-L860）；
- slash 候选浮层 + 键盘选择（L859）；
- context chip（issue 上下文）、会话历史。
- 结论：native composer 与自家 ACP 面板都不一致。

## 4. 改进建议（按优先级）

### P0 视觉与交互一致性（预计 1–2 天，低风险）— ✅ 已实施（2026-10-23，提交见 git log）
1. **单一 composer 卡片**：textarea + footer 放进同一个圆角卡片（复用 ACP 面板样式，聚焦 accent 边框）。
   - footer 左：`+` 上下文、模型、推理/thinking、审批模式（或移到权限卡片）；
   - footer 右：token usage、发送/停止/排队按钮。
   - 删除现有独立 toolbar 行，统一视觉。
2. **placeholder 对齐**：`给 CGC Agent 发消息… @ 引用上下文，/ 查看命令`（与 ACP/i18n 复用）。
3. **发送按钮状态机**：空闲空输入禁用；生成中空输入 = 停止；生成中已有输入 = 排队（图标 QueueMessage），⌘↩ 立即发送；tooltip 对齐。
4. **token usage 移入 footer**：显示本会话 tokens；hover 显示本轮 prompt/completion/cache。
5. **thinking 控件对齐**：thinking on/off + effort SplitButton（supports_thinking 才显示；默认值跟随 provider）。
6. **权限卡片升级**：Allow once / Allow for session / Always allow pattern（下拉选择）+ Reject；批量 Keep all / Reject all / Undo last；审批模式选择器移入卡片，不再占用 footer。

### P1 行为对齐（预计 3–5 天）
7. **Slash 命令弹层**：复用 ACP 面板的浮层实现（L559-670）+ `agent_host::slash`；输入 `/` 弹出、↑↓ 选择、Enter 执行、Esc 关闭；替换静态提示行。
8. **@ 上下文**：先做 workspace 文件/目录（输入 `@` 搜索文件，插入 chip；发送时作为 context block 前置给模型）；二期加 symbols / diagnostics / terminal selection / skills。
9. **队列 UI**：`HostState` 新增 `QueueEntry`（text / steer 标记），composer 上方渲染队列卡片，支持 edit / remove / steer / clear；接现有 follow-up sender。
10. **结构化状态卡片**：plan/todo/goal 与 checkpoint changes 渲染为 composer 上方卡片（Keep all / Reject all / Undo），替代 system 消息与独立面板。
11. **Subagent 内联卡片**：挂到对应 `task` tool call 的位置，显示运行中/awaiting permission/完成，而非独立列表。
12. **activity/follow**：生成中指示器（Thinking/Working）、follow toggle（自动滚动到底部）、loading context spinner。

### P2 深度能力
13. 富文本 editor（语法高亮、mention crease、图片粘贴/拖拽、展开编辑区）。
14. 本地 slash 命令扩展（/export、/search 等）与命令面板动作。
15. 附件/图片预览、token 预算提示、排队消息编辑。

## 5. 实现落点

- composer 重构：`crates/app/src/native_agent_view.rs`（合并 toolbar 与 textarea 为卡片；footer 控件）
- 状态/事件：`crates/agent_host/src/{events,state}.rs` 增 queue entries、plan/todo 结构化状态（usage 已有）
- 可复用组件：`gpui_kit::component::{popover, button, input, tag, tooltip, menu}`；ACP 面板的 slash 浮层与 composer 样式（`panel.rs` L559-860）
- 键盘动作：在 composer 上绑定 Enter/Shift+Enter/Cmd+Enter/Cmd+Shift+Enter，复用 `send` / `steer` / `stop` 逻辑
- 验收：native vs ACP 并排截图一致；键盘用例；队列手动验收；token footer 正确；slash 弹层键盘可选；HostState 归约单测。

## 6. 建议的第一个切片

**P0 #1–#3**（composer 单一卡片 + 发送状态机 + 键盘语义），因为：
- 直接解决「message editor 差别很大」的观感问题；
- 纯前端改动，不动协议/存储；
- 可复用 ACP 面板样式，风险低，做完即可并排对比验收。

之后做 P0 #4–#6，再进入 P1 的 slash 弹层与 @ 上下文。

## 7. P0 实施记录（2026-10-23）

已落地：
1. composer 收敛为单一圆角卡片（textarea + footer 同一容器），footer 左侧：`＋`上下文入口、模型、Thinking 开关、推理档位、审批模式；右侧：变更/撤销、本会话 tokens、发送按钮。
2. placeholder 对齐 ACP / Zed 提示（`@` 上下文、`/` 命令、Enter/Shift+Enter 提示）。
3. 发送按钮状态机：空闲空输入=禁用「发送」；空闲有输入=「发送」；生成中空输入=「停止」；生成中已有输入=「排队」。
4. token usage 从 header 移到 footer（本会话 tokens）。
5. Thinking 开关 + 推理档位（Off/Low/Medium/High）；关闭时不下发 `reasoning_effort`。
6. 审批卡升级：工具名 tag、操作说明、参数预览、允许一次 / 本会话允许 / 拒绝（danger）+ 说明文案。

键盘：Enter 发送/排队，Shift+Enter 换行，⌘↩ 生成中打断并立即发送（未生成时等同发送）。

**P1 进度**：slash 命令弹层已实现（输入 `/` 过滤、↑↓ 选择、Enter 执行、Esc 关闭、点击选择），composer 上方不再显示静态提示行。plan/todo/goal 结构化卡片已实现（composer 上方显示目标、计划步骤、待办与完成计数，替代 system 文本）。仍未做：@ 文件上下文、队列卡片、权限 pattern 粒度、subagent 内联。

### P0 视觉验收（2026-10-23，已解锁后实测）

- 通过 Agent Panel「+」→「CGC Agent」进入 native 模式，并截图确认：
  - composer 为**单一卡片**：placeholder 一行 + footer 一行；
  - footer 左起：`＋`、`deepseek-flash`（模型）、`Ask`（审批）；右侧：`0 tokens`、灰色「发送」；
  - provider 未开 supports_thinking 时**不显示推理档位**（符合预期）；
  - header 不再重复 usage，只显示 `model: ... · 已恢复上次会话`。
- 验收中发现并修复两处：恢复会话后 footer 显示 0 tokens（改为带入 thread.usage_total）；未支持 thinking 的 provider 仍显示「推理 —」（改为整体隐藏）。
