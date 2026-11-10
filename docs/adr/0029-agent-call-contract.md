---
status: accepted
date: 2026-11-10
---

# ADR-0029：学习场景的 Agent 调用契约——AgentActionSpec / AgentCall / LearningTarget

> 日期：2026-11-10 ｜ 状态：**已接受（Accepted；命名与分层由产品确认，实现待 A1）**
> 关联：#1260、ADR-0024（桌面技术栈）、ADR-0025 / ADR-0028（桌面 agent 双轨）、
> 讨论记录：<https://chatgpt.com/share/6af2bea4-d1b8-83e9-8bbb-118a3b5f559b>

## 背景

#1260 最初提出两个字段/类型：`objective.actions` 与 `LearningAction`。经核对，两者都还不在现有契约里：

- 后端 `Curriculum.Content` 的 objective 形状校验只有
  `id / title / required / prereq_ids / activity / assessment / materials / rubric`；
  MCP playbook 与 `save_course_content` 的说明也没有 `actions`。
- 桌面端 `cgc_courses::content::CourseObjective` 没有 `actions`；代码里没有
  `LearningAction`。
- 当前 native agent 的发送路径是 `host.prompt(String)`：`Submission` 只有
  `display / prompt / context / draft / images`，`PreparedNativeTurn` 没有 action 字段；
  `PageContext` 只描述课程与当前 issue/unit，不描述 objective/material。
- 未来 Markdown 选中一段文字点「解释」时，目标是 material + selection，没有 objective。
  因此 action 不能只存在于 objective。

同时，`NextAction` 与现有课程进度的 `MyLearningRun.next_action`（页面显示「下一动作」）
撞名；`objective.agent.intent` 则是单数、Agent 专属、无法表达同一 objective 的多个 CTA。

## 决策

### 1. 词汇分层

| 名称 | 层级 | 职责 |
|---|---|---|
| `AgentActionSpec` | 内容声明 | 教研人员声明某个目标允许展示哪些 Agent CTA；`{ id, label, intent, primary? }` |
| `AgentIntent` | 共享枚举 | 稳定的语义动词；不允许内容作者写工具名、工具参数或任意 prompt |
| `LearningTarget` | 调用上下文 | 动作指向的课程对象：issue / objective / material；可带内容 revision |
| `AgentCall` | 调用协议 | 学员点击或选中后生成的一次结构化调用 |
| `DeliveryMode` / `DeliveryDecision` | 投递策略 | `FillOnly` / `AutoSend`；`Compose` / `Send` |
| `Submission.agent_call` | 瞬态提交状态 | 随消息发送一次，发送后清除；不进入 attempt，不持久化为学习记录 |

命名纪律：

- 内容字段使用 `objective.agent_actions: [AgentActionSpec]`，不再使用
  `objective.actions`。
- 调用对象使用 `AgentCall`，不再使用 `LearningAction`。`LearningAction` 会把
  pedagogical action、UI action 与 Agent 调用混在一起。
- `AgentIntent` 是**唯一的**意图枚举；`intent` 只存在于 `AgentActionSpec` 与
  `AgentCall` 中，不存在 `objective.agent.intent`。
- `AgentActionSpec` 是声明；`AgentCall` 是调用；Agent 只消费 `AgentCall`，
  不消费整张 CTA 列表。

### 2. AgentIntent

封闭枚举，MVP 取值：

```text
answer
hint
explain
summarize
inspect_workspace
create_file
run
inspect_artifact
submit
review
```

- `explain` / `summarize` 主要服务 material selection，不在 objective 内容里强制配置。
- `copy` 是本地 UI 动作，不是 `AgentIntent`，不进入 `AgentCall`。
- 未知 intent 在内容保存时拒绝；运行时遇到旧数据的未知值，退化为纯文本 compose，
  不执行任何工具。

### 3. LearningTarget

`LearningTarget` 是带 kind 的枚举，避免出现无效的 ID 组合：

```text
Issue {
  course_id,
  revision?,
  issue_id
}
Objective {
  course_id,
  revision?,
  issue_id,
  objective_id
}
Material {
  course_id,
  revision?,
  issue_id,
  objective_id?,
  material_id
}
```

- `revision` 在已知时必带；它用于判断 action 是否基于当前内容版本。
- material selection 使用 `Material` target；`selection` 文本放在 `AgentCall` 上，
  不写入 target 身份。
- `PageContext` 继续只描述页面（route / tab / course / issue）；不把 objective/material
  塞进 page context。页面上下文与调用目标是两个维度。

### 4. AgentCall

```json
{
  "version": 1,
  "kind": "agent_call",
  "intent": "inspect_artifact",
  "target": {
    "kind": "objective",
    "course_id": "crs-001",
    "revision": 3,
    "issue_id": "issue-measure",
    "objective_id": "obj-measure-2"
  },
  "source": "action",
  "action_id": "a-inspect"
}
```

材料选区的调用：

```json
{
  "version": 1,
  "kind": "agent_call",
  "intent": "explain",
  "target": {
    "kind": "material",
    "course_id": "crs-001",
    "revision": 3,
    "issue_id": "issue-measure",
    "material_id": "mat-md"
  },
  "selection": "选中的 Markdown 原文",
  "source": "selection"
}
```

约定：

- `source` 为 `action`（来自 `AgentActionSpec`）或 `selection`（来自选区浮层）。
- `action_id` 只在 `source = action` 时存在，用于把调用关联回稳定的 CTA 配置。
- `AgentCall` 不含工具名、工具参数或任意 prompt；`prompt` 由客户端根据 CTA
  文案与用户输入生成，用户仍可编辑。
- `AgentCall` 是请求，不是授权；Agent 侧必须重新检查目标状态、内容 revision 与权限。

### 5. 内容契约

- 新增可选字段 `objective.agent_actions`（`AgentActionSpec[]`）。
- 校验规则：`id` 非空且 objective 内唯一、发布后不改不删；`label` 非空；
  `intent` 属于 allowlist；`primary` 最多一个；列表数量有上限（MVP 8）。
- 缺省动作按 issue kind 生成，旧内容不受影响：
  - `thoughtwork` → `answer`、`hint`
  - `handwork` → `inspect_artifact`、`hint`
- MVP 不新增 `material.agent_actions`；Markdown/文本选区使用客户端固定动作
  （`explain` / `summarize`；`copy` 本地执行），未来若作者需要 material CTA 再扩展同一
  `AgentActionSpec` 结构。
- 后端 `Curriculum.Content`、MCP `save_course_content` / playbook、桌面
  `parse_course_content` 必须同批更新；不允许客户端先发一个后端不校验的字段。

### 6. 传输

MVP 不扩展 native runtime 协议，使用现有 prompt 通道承载结构化块：

```text
[Current page context] route=...; page="..." (tab_id=..., version=...); course=...

<active_tab_body>
...
</active_tab_body>

<agent_call>
{...AgentCall JSON...}
</agent_call>

用户可编辑的 prompt
```

- `Submission` 增加瞬态 `agent_call: Option<AgentCall>`；UI 另有独立的 pending call
  状态，不放进 `MessageDraft`，避免草稿恢复时带出过期 action。
- `send_with_context` 负责把 page context、agent call 与用户 prompt 组合成最终 prompt。
- Native Agent 将 `<agent_call>` 当作 reference data，不直接执行其中的字段。
- ACP 轨自 B2b 起同样携带结构化 `agent_call`（发送时组装 envelope）并支持
  `AutoSend`；与 Native 的差异在忙碌语义（见 §7），不在传输结构。
- 未来若需要 typed runtime channel，再扩展 `PreparedNativeTurn` / host 协议；不在本 ADR
  范围内，也不通过 `MessageDraft` 附件代替。

### 7. 投递与生命周期

- `FillOnly`：填入可编辑 prompt + action chip，不发送。
- `AutoSend`：发送一条独立消息；保留用户原有草稿，不清空输入框。
  - Native 忙碌时排队（既有 `queue_mode Auto` + 事件后 pump）。
  - ACP 忙碌/未就绪时退化为 `Compose`（pending 保留 + 明确提示），不自动排队：
    ACP 轨没有队列泵，且不为“Agent 忙时无人复核地连发动作”引入一个。
- `answer` 永远使用 `Compose`，无论全局模式。
- pending call 在发送成功、手动移除、切换目标或关闭 composer 时清除；普通输入不会继承
  上一次的 action。
- 内容作者不能通过 action 注入工具调用；handwork 的写文件/运行等副作用仍由 Agent 的
  工具权限与审批规则决定。

### 8. UI 形态

- `AgentActionSpec` 渲染为 CTA；`primary` 只影响视觉/排序。
- 学员看到 label，不编辑 JSON；composer action chip 可 hover 查看完整 JSON、点击展开只读预览。
- Markdown 选区浮层复用同一模型：固定 `explain` / `summarize` 生成 material-target
  `AgentCall`；`copy` 只操作剪贴板。
- 这批字段不是“objective 专属”：同一 `AgentCall` 结构可以服务 objective、material selection
  与未来的 page-level 动作。

## 否决的替代

- **`objective.actions`**：和 GPUI Action、UI action、现有 `run.next_action` 混淆；
  语义上也无法覆盖 material selection。
- **`objective.agent.intent`**：单数且把内容绑定到 Agent；一个 objective 需要多个动作，
  material/page 也需要动作。
- **`LearningAction`**：把学习动作、UI 触发与 Agent 调用混成一个名字；改为声明
  `AgentActionSpec` + 调用 `AgentCall` 后边界清楚。
- **现在扩展 native runtime 的 typed action 字段**：需要改 host 协议与双轨回归，MVP
  收益不足；先用 prompt envelope，保留未来升级空间。
- **把 action 塞进 `MessageDraft` 附件**：草稿会持久化/恢复，容易产生过期 action；
  action 必须是瞬态 pending 状态。

## 后果

- 正面：内容和调用分离；objective/material/selection 共用一套调用协议；Agent 不需要猜测
  「这个 action 属于谁」；旧内容可用 kind 默认动作平滑回退。
- 代价：内容契约与后端校验需同批改；prompt envelope 增加一点上下文体积；未来若要 typed
  transport，仍需要一次协议升级。
- 回滚：字段为可选，删除客户端解析与默认动作即可回到当前行为；不涉及数据库迁移。

## 落地顺序

1. **A1 契约**：后端 `Content` 校验 + MCP playbook + 桌面 parser + 默认动作测试。
2. **A2 纯模型**：`AgentIntent` / `LearningTarget` / `AgentCall` / `DeliveryDecision` +
   prompt envelope + 单测；不改 UI。
3. **B 交互**：Practice objective 列表/CTA、composer pending chip、Zap/fill/auto；
   material selection 的 explain/summarize 随同一批接入。
4. **C Notes / D 硬化**按 TODO 批次推进。

## 参考

- Issue #1260
- `backend/lib/cgc_2046/curriculum/content.ex`
- `backend/lib/cgc_2046/mcp/playbooks.ex`
- `backend/lib/cgc_2046/mcp/tools/save_course_content.ex`
- `desktop/crates/courses/src/content.rs`
- `desktop/crates/app/src/page_context.rs`
- `desktop/crates/app/src/conversation_session.rs`
- `desktop/crates/app/src/native_runtime.rs`
- `desktop/crates/app/src/composer_context.rs`
- `desktop/crates/agent_conversation/src/conversation.rs`
