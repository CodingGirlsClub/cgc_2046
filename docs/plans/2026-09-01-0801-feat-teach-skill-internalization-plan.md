---
title: Teach Skill 内化 —— 学习模式教学法与教学记忆升级 - Plan
type: feat
date: 2026-09-01
topic: teach-skill-internalization
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: docs/plans/2026-08-29-1110-feat-role-agent-journeys-v2-plan.md（R36–R50 学习契约全文继承；本计划增量 R51–R58）
baseline: origin/develop @ de500aa
execution: code
---

# Teach Skill 内化 —— 学习模式教学法与教学记忆升级

> 修订记录：v2（2026-09-01）——product owner 裁决 D5：内化主载体从「平台实体 + playbook 全文」调整为「**三层内化模型**」——方法论进 CGC 适配 skill（扩展分发）、调度进 playbook、事实留平台账本；handwork 卡新增 think / check 内化（R58）。

## Goal Capsule

- **Objective:** 把三个通用 skill 内化到 CGC 学习模式，按卡片类型分流：**thoughtwork（知识学习卡）内化 teach skill**（认知科学教学法 + 教学记忆），**handwork（动手卡）内化 think / check skill**（动手前共建规划、动手后系统化评审）。学员侧 BYO agent 在学习与动手过程中**明确使用这些技能**；未安装时随 cgc-2046 扩展安装。
- **Means（三层内化模型）:** ①方法论 → 三个 CGC 适配 skill（`cgc2046-teach` / `cgc2046-think` / `cgc2046-check`），静态打包进扩展（`cgc2046-onboarding` 先例）；②调度与平台协议 → learner playbook 升级（按卡片 kind 分流到 skill + attempt / 掌握态 / 先修锁纪律留在 playbook）；③事实与账本 → 平台实体（Attempt 已在；新增 Insight 洞察账本 + Artifact 复习笔记）。
- **不动摇的边界:** 确定性路径算法属网站（R39–R46 / NextAction 五级骨架不因洞察改变）；教学对话与 CoT 留本地（R47/AE12）；平台零 AI 成本（D3——skill 是 agent 行为规范，账本由 agent 经工具提交，平台不做任何生成）；平台安全纪律（工具协议 / 先修锁 / 掌握态只读）必须留在 playbook 上层提示词，不下沉进 skill（skill 可缺席，平台纪律不可）。
- **Stop conditions:** 每切片 `mix precommit` + 扩展 minitest + 门禁（wrapper_gate_test 工具数钉死 / error codes contract / migration snapshot）全绿方可合入。

---

## 第一部分 · 决策记录（product owner 裁决）

### D1 — Mission 不做（整体砍掉）

teach skill 要求用户输入 MISSION.md（学习动机锚），因为它的目标场景是**无课程设计者的自主学习**。CGC 是**课程驱动**场景：教研 issue 卡的 `story.goal` + `story.given` + 课程级 `goals` 已承担 mission grounding 的全部职能；学员报名行为本身即动机表达。

裁决：**不建 LearningMission 实体、不做学员 mission 采访、不做报名 reason 字段联动**。

### D2 — Insight 与 Attempt 的分工写明（ADR-0012 立条）

**Attempt 锚 (run, objective) 记录评价结果**；**Insight 锚 (user, course) 记录跨评价的认知事实**（先验知识 / 误区修正 / 教学偏好）。Attempt.rationale 是"本次判定理由"，不得复写为 Insight（防灌水，R53）。

### D3 — 复习笔记不进完成判定

完成判定只看必修 ever_mastered（R39 不动）。笔记是复习资产不是评价对象；纳入判定会让 agent 替学员刷产物，账本失真。

### D4 — R46 七步骨架不动

教学法以纪律追加与 skill 承载（R51/R58），R46 的七步循环结构不变。

### D5 — 内化走三层模型：skill 分发为主，不全平台化（v2 裁决）

"不一定完全把这些技能变成平台的"——三个 skill 的内化按层拆解归属：

| 层 | 内容 | 载体 | 理由 |
| --- | --- | --- | --- |
| **方法论**（怎么教 / 怎么规划 / 怎么评审） | 认知科学教学纪律；动手前规划纪律；产物评审纪律 | **CGC 适配 skill**，静态打包进扩展 `contributes.skills` | 模块化、按卡片类型按需加载、独立演进；playbook 塞三个方法论会膨胀到不可维护；"明确使用这些技能"的自然表达 |
| **调度与协议**（何时用哪个 skill、结果如何回平台） | 按 kind 分流；attempt / 掌握态只读 / 先修锁 / 复习纪律 | **learner playbook**（网站版本化分发） | 平台安全纪律必须在上层提示词，不随 skill 缺席而失效 |
| **事实与账本**（评价结果 / 掌握态 / 洞察 / 笔记） | Attempt（已在）+ Insight / Artifact（本计划新增） | **平台实体 + MCP 工具** | R47 跨会话恢复、R48 tutor 可读、R49/R50 教研回流——skill 是本地行为规范，无共享状态 |

存量扩展兼容：playbook 调度段内置一句话级最小纪律 fallback + 提示更新扩展（不做 skill 版本协商机制）。

### 拒绝项清单（防止未来重新发明）

| 拒绝项 | 理由 |
| --- | --- |
| LearningMission 实体 / mission 采访 / 报名 reason 联动 | D1：课程驱动场景 mission 由教研承担 |
| Insight kind `mission_shift` | 随 D1 砍掉 |
| 教学方法论文本复制进 playbook（与 skill 双源） | D5：playbook 只写调度与引用，方法论单源于 skill；防双源漂移 |
| 照搬原版 think / check skill 全文分发 | 原版面向工程师 agent（release gate / audit 模式 / durable context / scripts）；学员场景只需规划与评审内核，须裁剪重写为 CGC 适配版（见 §第四部分 D） |
| v1 走 D11 工作区 Skill 同步分发 | 教学法是平台级资产不分工作区；扩展静态打包最简（onboarding 先例）；工作区自定义教学法出现真实需求时再开 |
| skill 版本协商 / 扩展最低版本门禁 | 过度设计；v1 用 playbook fallback 一句话兜底 |
| lesson HTML 上平台 | teach skill 自判"lessons 很少被重访"；lesson 是过程产物留本地；上平台的只有结构化压缩笔记（R54） |
| NextAction 消费 insight / mission 改骨架 | 确定性五级优先是教学正确性底线；洞察给 agent 侧算 ZPD |
| NOTES.md 式独立偏好文件 | 归并进 Insight kind `preference`；平台是唯一教学状态源 |
| community / wisdom 层 | teach skill 的"社区测技能"在 CGC 映射为活动与作品展示（Event 域），不在学习循环内造 |

### 三个 skill 对照盘点（缺口 → 本计划）

| skill 概念 | 学习 v2 现状 | 本计划 |
| --- | --- | --- |
| teach: Spacing（1/7/30 天） | ReviewSchedule 平台确定性调度 | 已有，强于原版，不动 |
| teach: Retrieval practice | 复习 = 重新正式评价 | 已有；cgc2046-teach 补教学循环内"先检索再讲解" |
| teach: "Wait for evidence" | 掌握只认 qualifying attempt | 已有，不动 |
| teach: ZPD 认知侧信号 | 无（Attempt 只记评价结果） | T2：Insight 账本 |
| teach: Reference 层 | 无（课后无可复习产物） | T3 复习笔记 + T4 教研 glossary |
| teach: RESOURCES 策展 | materials 朴素 `{title, ref}` | T4：`when_to_use` |
| teach: Fluency vs storage 纪律 | playbook 无显式表述 | cgc2046-teach |
| think: 动手前 decision-complete 规划 | playbook 一句"引导学员动手产出可检查的产物"，无方法论 | cgc2046-think（R58 前段） |
| think: 先查官方方案 / 最小实现 | 无 | cgc2046-think 裁剪保留 |
| check: 系统化产物评审 | rubric 逐条反馈有（R44），无评审方法论；"可检查产物"判定散落 tutor 措辞纪律 | cgc2046-check（R58 后段） |
| check: 边界 / 错误路径审查 | 无 | cgc2046-check 裁剪保留 |

---

## 第二部分 · Product Contract（增量 R51–R58）

### Requirements

**教学法与 skill 分发**

- R51. thoughtwork 卡的教学循环必须执行认知科学纪律：①讲解前先让学员回忆或预测（retrieval before re-exposure），②单一 objective 一次教学给一个可带走的胜利，讲解短小守工作内存，③警惕学员流利度错觉——自述"会了"必须经正式评价验证（与 confidence ≥ 0.8 连线），④到期复习与新 objective 练习交错安排。纪律全文单源于 `cgc2046-teach` skill（扩展分发），learner playbook 按卡片 kind 调度并引用，不复制内容；skill 缺席时 playbook 内置的一句话最小纪律兜底并提示更新扩展。R46 七步骨架不变。Governs T1。
- R58. handwork 卡的教学循环必须经五段：**共建规划 → 学员动手 → 产物评审 → 反馈修复 → 达标提交**。规划方法论由 `cgc2046-think` skill 承载（与学员共建 decision-complete 小计划：做什么 / 步骤 / 验收标准对照 rubric / 最小实现路径 / 先查官方方案再自造，学员确认后动手）；评审方法论由 `cgc2046-check` skill 承载（rubric 逐条 + 产物可验证性——能运行 / 能读取 / 能展示 + 边界与错误路径）；两 skill 随扩展分发，playbook 按 kind 调度。agent 协助调试但**关键步骤由学员独立执行**（agent 代做关键步骤 = 教学失败）；attempt.evidence 必须引用产物位置与评审结论。Governs T1。

**教学记忆（平台账本）**

- R52. 学员洞察必须作为不可变 `Learning.Insight` 账本保存：kind 枚举 `prior_knowledge` / `misconception` / `preference`；锚定 (user, course) 跨 run 存活，可选携带 objective_id / learning_run_id 上下文引用；仅追加不可改写。写面仅学员本人（agent 经 `save_learning_insight` 提交），读面本人 ∪ 本台 tutor/owner/admin。Governs T2。
- R53. 洞察提交纪律：仅记 decision-grade 认知事实（学员披露了先验 / 修正了误区 / 表达了偏好），不记教学内容流水；kind 之外无 evidence 语义，Attempt.rationale 不得复写为 Insight。判定标准单源于 cgc2046-teach skill，playbook 引用。Governs T2。
- R54. 学员可经 `save_learning_artifact` 为某 objective（可空 = 课程级）维护**最新版**复习笔记（markdown，upsert 覆盖）：跨 run、跨 revision 保留，跨会话恢复（`get_learning_state` 附带）。笔记永不进入完成判定（D3）；由 agent 在教学达成时生成、学员可要求改写。Governs T3。

**教研内容升级**

- R55. CourseRevision 草稿内容支持两个可选新键：①objective.materials 条目增 `when_to_use`，②课程级 `glossary`（`%{term, definition, avoid?}`）。二者可选——存量课程与既有门禁不受影响；教学措辞遵守 glossary、按 when_to_use 挑选引用资源（纪律在 cgc2046-teach）。Governs T4。

**审计与回流**

- R56. 学习洞察与笔记的 MCP 审计只记操作引用（workspace_id / course_id / objective_id / kind），正文**不落 ToolCallLog**（`submit_learning_attempt` 白名单收窄同款先例）。Governs T2/T3。
- R57. `get_course_learning_analytics` 必须聚合洞察维度：per-objective 的 misconception 计数与封顶样本，样本不含完整对话；tutor 据此可发起新 revision 草稿（R50 语义不变）。Governs T4。

### Acceptance Examples

- AE15. **Covers R51.** Given 学员对当前 thoughtwork objective 自述"这个我已经会了"，When agent 执行教学循环，Then agent 先以检索式提问验证而非直接跳过，确认后直接进入正式评价；学员答得流利但 rubric 未全 met 时，agent 如实提交 failed attempt 并针对性反馈，不因流利而放行。
- AE16. **Covers R52, R53, R56.** Given 学员披露"我日常已在用 Elixir 模式匹配"，When agent 调 `save_learning_insight(kind=prior_knowledge)`，Then 不可变账本新增一行、审计行只含操作引用；后续新会话 `get_learning_state` 返回该 insight，agent 据此跳过基础讲解直接诊断深化。
- AE17. **Covers R52, R57.** Given 多名学员在同一 objective 提交 `misconception` 洞察，When tutor agent 调 `get_course_learning_analytics`，Then 该 objective 的 misconception 计数与封顶样本可见且不含完整对话，tutor 可据此起草新 revision 建议。
- AE18. **Covers R54.** Given 学员首次掌握某 objective，When agent 生成压缩笔记并调 `save_learning_artifact`，Then upsert 成功；When 学员更换会话或课程发布新 revision 后重学，Then 笔记经 `get_learning_state` 仍可恢复；笔记存在与否不影响 run 完成判定。
- AE19. **Covers R55.** Given tutor 为新 revision 的 materials 补 `when_to_use` 并附课程 glossary，When 提交 `save_course_content`，Then 结构门禁通过（新键可选）；When 学员 agent 教学该课程，Then 讲解措辞遵守 glossary、按 when_to_use 选择引用资源。
- AE20. **Covers R58.** Given 学员开始 handwork objective，When agent 执行学习循环，Then ①先按 cgc2046-think 与学员共建规划（验收标准逐条对照 rubric，学员确认后才动手），②学员动手产出（agent 仅协助调试，关键步骤学员独立执行），③产出后按 cgc2046-check 评审（rubric 逐条 + 能运行/能读取/能展示 + 边界与错误路径），④评审发现作为反馈进入修复循环，⑤达标后提交 attempt 且 evidence 引用产物位置与评审结论。Given 学员装的是不含技能的旧扩展，When playbook 调度段触发，Then 一句话最小纪律兜底并提示更新扩展。

### Success Criteria

- 学员的 agent 在 thoughtwork 卡上表现出认知科学教学法（先检索后讲解、单一胜利、警惕流利度错觉），在 handwork 卡上表现出规划—动手—评审闭环（动手前有共建计划，产出经过系统化评审）。
- 三个 CGC 技能随扩展安装即得；存量扩展用户有一句话兜底 + 更新提示，学习不中断。
- 学员在会话之间不丢失"教练对学员的认知"：先验与误区跨会话、跨 run 可见；objective 级压缩笔记随时可重访、换设备可恢复。
- tutor 能从 analytics 看到"学员群体在哪些 objective 想错、怎么错的"。
- 审计红线不回退：洞察正文与笔记内容不出现在 ToolCallLog / 平台治理读面。

---

## 第三部分 · 基线核对（develop @ de500aa）

| 面 | 现状 | 缺口 |
| --- | --- | --- |
| 扩展 skill 分发 | `skills/cgc2046-onboarding` + `ext.yml contributes.skills` + `cgc-assistant.skills` 挂载，v0.2.0 生产在跑 | +3 CGC 教学法 skills |
| learner playbook | v2026-08-30.2；学习循环第 4 步已按 thoughtwork/handwork 分流但各只有一句 | 调度段 + fallback（R51/R58） |
| 教学记忆 | Attempt + Mastery/ReviewSchedule/NextAction 投影 | 洞察与笔记两类记忆零 |
| MCP 工具面 | 60（gate test 钉死） | +2：save_learning_insight / save_learning_artifact |
| `get_learning_state` | run/objectives/review_queue/next_action/progress | +insights/+artifacts |
| 审计收窄 | `redact.ex` per-tool 白名单先例 | +2 工具白名单 |
| 课程内容 schema | `Curriculum.Content` v2 校验（materials `{title, ref}`） | when_to_use、glossary 可选键 |
| analytics | run_stats + 四态/重试热点/低置信度 | misconception 聚合 |
| tutor playbook | 起草规则 7 条 + 提交纪律 | materials 注释、glossary、handwork rubric 措辞与 check 维度衔接 |

---

## 第四部分 · 技术设计

### A. ADR-0012 草案：学习洞察与复习笔记账本（Insight / Artifact）

> 状态：草案（随本计划评审）。对照：ADR-0011（Attempt 账本纪律全文继承）；teach skill 的 learning-records 与 reference 层理念。

**L1 — `Learning.Insight`：不可变洞察账本（append-only）。**
属性：`workspace_id`（租户，writable? false）/ `user_id`（学员锚）/ `course_id` / `kind`（枚举 atom：prior_knowledge / misconception / preference）/ `content`（文本，必填）/ `objective_id`（string 可空——跨 revision 稳定 id）/ `learning_run_id` / `course_revision_id`（可空上下文引用）/ `agent_meta` / 仅 `created_at`。actions 只有 `:create` 与 `:read`。
**锚定 (user, course) 而非 run**：洞察是认知事实不是版本事实——与 ADR-0011 L3"账本挂人，掌握态挂 run × revision"同族。写面 = 仅 `user_id == actor.id`（fail-closed 按列判等）；读面 = 本人 ∪ 本台 tutor/owner/admin（`ActorReadsLearningAttempt` 同款）；平台管理员刻意不放行（同 Attempt 红线）。不开 GraphQL 面。

**L2 — `Learning.Artifact`：最新版复习笔记（upsert）。**
属性：`workspace_id` / `user_id` / `course_id` / `objective_id`（可空 = 课程级）/ `content`（markdown，上限 10_000 字符）/ `agent_meta` / `created_at` / `updated_at`。唯一键 `(workspace_id, user_id, course_id, objective_id)`，`:upsert` 整行覆盖。**与 Insight 相反是最新值**：复习资料要"当前版"，账本语义由 Insight 承担。Policy 同 L1。不进完成判定（D3 入 ADR 拒绝项）。

**L3 — 投影单源：`Learning.Runs.learning_state/2` 扩展。**
追加 `insights`（本人该课程 created_at desc 封顶 50 条——agent 侧 ZPD 输入）与 `artifacts`（本人该课程笔记列表——跨会话恢复输入）。GraphQL `courseLearningDetail` 与 MCP 共用单源。

**L4 — 工具面（60 → 62）。**
`save_learning_insight(workspace_id, course_id, kind, content, objective_id?)` 与 `save_learning_artifact(workspace_id, course_id, objective_id?, content)`：授权 = `GetLearningState` 同款（`membership: :deferred` + LearnerAuthorization）；直接写非确认流（低风险个人学习写，attempt 同级）；artifact 响应明示 created / updated。

**L5 — 审计收窄。**
`redact.ex` 增两条白名单：`save_learning_insight` 留 `workspace_id/course_id/objective_id/kind`；`save_learning_artifact` 留 `workspace_id/course_id/objective_id`。

**L6 — analytics 洞察维度。**
`Analytics.compute/5` 输入追加课程 insights：per-objective misconception 计数 + 最近样本封顶 3 条（每条截断 200 字符）+ prior_knowledge 聚合计数。

**拒绝项：** Insight supersession 链；Artifact 进完成判定（D3）；两工具开确认流；洞察带评分 / sentiment 结构；handwork 评审结论建独立实体（结论进 attempt.evidence / rationale，零 schema 变更）。

### B. 三个 CGC 教学法 skills（扩展分发，本计划核心增量）

> 设计原则：**裁剪重写，不照搬原版**。原版 think（15KB）与 check（30KB + scripts/agents/references）面向工程师 agent 的 repo/PR/release 场景；学员场景只取规划与评审内核。原版 teach 的本地文件态（MISSION/lessons/reference 的 md/html 文件）被平台账本替代——skill 指令是"调 MCP 工具读写"而非"写本地文件"。

**B1 — `cgc2046-teach`（thoughtwork 教学纪律）。**
内容要点（自 teach skill 裁剪）：
- 教学循环纪律：检索优先（讲解前先让学员回忆/预测）、单一胜利（一个 objective 一个 tangible win，守工作内存）、流利度错觉警告（自述会了 → 检索验证 → 正式评价说了算）、交错复习（review 到期与新目标混排）；
- 知识来源纪律：以 objective.materials 为信任源并注明出处，`when_to_use` 存在时按其选资源；课程带 glossary 时全程使用规范术语；
- 教学状态读写映射（替代原版文件态）：课程地图/掌握态 = `get_learning_state`（读）；learning records = `save_learning_insight`（写，含 R53 decision-grade 判定标准与三 kind 释义）；reference 笔记 = `save_learning_artifact`（写，objective 掌握后生成压缩笔记：定义、一个例子、一个坑）；
- 诊断纪律：教学前先读 insights（先验/误区），已披露的先验直接以检索验证跳过基础讲解；
- 不携带：MISSION 采访（D1）、lesson HTML 生成（留本地对话）、quiz 等长/assets 组件库（Phase D）、community 推荐。

**B2 — `cgc2046-think`（handwork 规划）。**
内容要点（自 think skill 裁剪）：
- 与学员**共建** decision-complete 小计划：做什么（目标一句话）/ 步骤（最小实现路径）/ 验收标准（**逐条对照 objective rubric**，学员能复述）/ 依赖（工具、账号、环境）；学员确认后才动手——规划本身是学习内容，不是 agent 单方面出计划；
- 先查官方方案：动手前先查框架内置/官方文档/生态标准（materials 是首选信任源），"现有官方方案是默认推荐，除非能说出它为何不够"；
- 轻量为主：学员任务是学习性动手不是工程大项目，计划一屏内；出现 3 个以上真分歧才升完整模式；
- 明确不做清单（agent 代做关键步骤 = 教学失败）：写核心代码、替学员操作环境；协助调试时先让学员描述预期行为。
- 不携带：Evaluation/Triage 模式、durable context、attack angles、handoff 导出、Waza 沉淀。

**B3 — `cgc2046-check`（handwork 产物评审）。**
内容要点（自 check skill 裁剪）：
- 评审维度：objective rubric 逐条 + 产物可验证性三问（**能运行 / 能读取 / 能展示**——与 tutor playbook"可自验措辞"同源）+ 边界情况（空输入 / 异常路径 / 极端值）+ 错误处理（失败时行为是否明确）；
- 评审纪律：发现按"阻断 / 建议"分级，阻断项必须修复后才能提交 attempt；评审针对产物不针对人，反馈给到具体位置与复现路径；
- 与评价衔接：达标后 attempt.evidence 引用产物位置 + 评审结论摘要（"rubric N/N met，边界 X 项通过"）；发现的真实误区按 R53 记 misconception 洞察；
- 学员独立性：评审发现以引导学员自修复为主（"这里跑一下空输入看看"），agent 不直接改学员产物。
- 不携带：release gate / ship / audit / triage 模式、scripts（release_gate.py 等）、公开回复规范、persona catalog。

**B4 — 分发与挂载。**
- `ext.yml`：`contributes.skills` +3 条；`agents.cgc-assistant.skills` 追加三个 id（onboarding 先例）；
- 每个 skill frontmatter 写触发描述（"thoughtwork 学习卡教学时 / handwork 动手卡规划时 / 学员产物评审时"）——与 playbook 调度段点名 skill id 形成双保险触发；
- 扩展 minitest：manifest 校验 + skill 文件存在性。

### C. Playbook 升级（调度层，非方法论层）

learner playbook "三、学习循环" 第 4 步改写为按 kind 分流的调度段：
- thoughtwork：按 **cgc2046-teach** skill 的教学纪律执行（检索优先 / 单一胜利 / 流利度错觉 / 交错复习，纪律全文见 skill）；
- handwork：按 **cgc2046-think** 共建规划（验收对照 rubric、学员确认后动手）→ 学员动手（关键步骤学员独立执行）→ 按 **cgc2046-check** 评审产物 → 反馈修复 → 达标提交（evidence 引用产物与评审结论）；
- fallback（旧扩展无 skill）：一句最小纪律（"讲解前先让学员回忆验证；动手前先对齐验收标准，产出后逐条对照 rubric 检查"）+ 提示用户更新扩展获取完整教学法；
- 平台协议纪律保留在 playbook（不下沉 skill）：attempt 提交形状、掌握态只读、先修锁不可绕过、复习纪律、洞察/笔记工具的调用入口。

tutor playbook 起草规则追加：
- 第 6 条（materials）升级：条目带 `when_to_use`（一句话），引用高信任来源；
- 新增第 8 条（glossary）：课程有领域术语时附 glossary，"定义写学员半年后还看得懂的一句话"；
- handwork 衔接条目：rubric 条目即 check 评审维度——措辞必须是"能运行/能读取/能展示"式可判定语句，避免"理解了/掌握了"。

版本号：learner / tutor 各 bump。

### D. 课程内容 schema 演进

`Curriculum.Content` 校验放宽（可选新键，存量零影响）：
- objective.materials 条目：`{title, ref}` → `{title, ref, when_to_use?}`；
- content 顶层：`%{"goals" => [...], "issues" => [...], "glossary" => [...]}`（glossary 可空；条目 `%{term, definition, avoid?}`，term 课程内唯一）；
- `get_course_content` 投影透传新键。

---

## 第五部分 · 切片

| 切片 | 内容 | 依赖 | 验收 |
| --- | --- | --- | --- |
| **T1 三技能 + 调度** | 三个 CGC 适配 skill 起草（§B1–B3，洞察/笔记指令段引用的工具尚不存在时该段标注"工具上线后启用"并随 T2/T3 解锁）；ext.yml 挂载；扩展 minitest；learner playbook 调度段 + fallback + version bump | 无 | precommit + 扩展 minitest；manifest/存在性断言；playbook 调度措辞断言（kind 分流 + 三 skill 点名 + fallback 在册）；AE20 后半（fallback）可验 |
| **T2 洞察账本** | `Learning.Insight` + migration + policies；`save_learning_insight`；`get_learning_state` +insights；redact 白名单；gate 60→61；cgc2046-teach 洞察指令段解锁 + skill 版本 bump；playbook 洞察入口一句 | T1 | precommit；AE16 全断言；policy 钉测（本人写 / tutor∪owner-admin 读 / 平台管理员拒） |
| **T3 复习笔记** | `Learning.Artifact` + migration + policies（upsert）；`save_learning_artifact`；`get_learning_state` +artifacts；redact 白名单；gate 61→62；cgc2046-teach 笔记指令段解锁 + skill 版本 bump | T2 | precommit；AE18 全断言（upsert / 跨 run 恢复 / 完成守卫钉测不变绿） |
| **T4 教研内容 + 回流** | Content schema 可选键；tutor playbook 升级（materials/glossary/handwork 衔接）；learner playbook glossary 纪律引用；Analytics +insights 维度 | T2；T1 | precommit；AE17 / AE19 全断言；存量内容门禁照过回归 |

**顺序：** T1 → T2 → T3 → T4；T3 与 T4 在 T2 合入后可并行（不同文件面，gate 名单各自递增——role-agent-journeys-v2 S2/S3 同款纪律）。

**Phase D — 本地教学 workspace（defer，不在本计划执行范围）**
teach skill 完整文件态（lessons/*.html、assets 组件库）经 D11 Skill 同步下发为独立「CGC 学习 Skill」。触发条件：T1–T4 上线后，学员对"课程内可重访的本地教学产物"出现真实需求且平台笔记不足以覆盖。明确不在 v1 建：HTML 产物托管、组件库版本管理、lesson 索引。

---

## 验收映射

AE15→T1+T2（skill 纪律 + 洞察）｜ AE16→T2 ｜ AE17→T2+T4 ｜ AE18→T3 ｜ AE19→T4 ｜ AE20→T1（skill 与调度；后半 fallback）。Success Criteria："agent 表现出教学法与规划评审闭环"→T1；"技能随扩展安装/兜底"→T1；"认知跨会话不丢"→T2/T3；"笔记可重访"→T3；"tutor 看到误区聚合"→T4；"审计红线不回退"→T2/T3。

---

## Open Questions（评审时定）

1. **misconception 样本的隐私边界**：analytics 返回洞察正文样本（封顶 3 条 × 200 字符）是否需要剥除学员可识别语境？倾向 v1 不剥（R48 允许 tutor 读必要证据），响应中标注"洞察正文，仅教研用途"。
2. **insight 频控**：playbook/skill 纪律之外是否加工具层硬限（每 run 每天封顶 N 条）防灌水？倾向 v1 靠 skill 判定标准 + kind 枚举，观察流量再定。
3. **课程级与 objective 级笔记的恢复展示顺序**：倾向课程级置顶。
4. **skill 的 T1 占位问题**：cgc2046-teach 的洞察/笔记指令段依赖 T2/T3 工具，T1 先标注"工具上线后启用"是否可接受（think skill 硬规则禁占位符——此处是分片启用标记而非计划占位，需评审确认措辞）；备选：T1 的 teach skill 只写教学纪律，洞察/笔记段整体随 T2/T3 增补（推荐）。

---

## 变更影响（文档侧，随切片入册）

- CONTEXT.md：新增 Insight / 复习笔记词条；「连接器扩展」词条补三个教学法 skill；「角色 Playbook」learner 段落版本同步；MCP 工具集词条 60→62。
- ADR-0012 落 `docs/adr/0012-learning-insight-artifact-ledger.md`（随 T2 评审定稿）。
- `领域模型定稿.md` §5.4 Learning 行追加 Insight/Artifact。
- 扩展 README：三个 skill 的用途与更新说明。
