# 课程 Issue 学习闭环详细设计（自适应学习 v1）

> 日期：2026-08-16 ｜ 状态：**v1.0 定稿（grill 两轮 Q1-Q14 全部拍板落盘）** ｜ 来源：2026-08-16 brainstorm 对话收敛 + grill 会话（含代码事实核查）
> 依据：`教研workflow详细设计.md` v1.2、`学习workflow详细设计.md` v1.0、`CONTEXT.md`（BYO / D4 / D10 / D11 / D12）、`cgc_2046-dsh-plugin/dsh-plugin/CONTRACT.md`、Linear 交互词汇表（用户拍板）
> 定位：把「教研产出 → 课程内容 → 学员自适应学习 → 学习记录回流」整条链路打通的最小闭环设计。交互隐喻 = **Linear**（Course = Project，学习单元 = Issue）。

---

## 0. 一句话

> **教研产 issue 卡（内容契约），平台存内容与学习记录（哑存储），学员 agent 拉「内容 + 记录」跑自适应教学循环（算法在 agent），记录沉淀为个人学习记忆库（未来可下载导出）。**

三个拍板支柱：

1. **记忆在平台，算法在 agent**：平台只存结构化数据、暴露读写工具、做进度投影；教学与自适应决策全部以指令形式分发、由学员 BYO agent 执行。平台零算法。
2. **内容与策略分离**：issue 卡是纯内容契约（讲什么/练什么/怎么判定完成）；「怎么教、何时补救、何时跳过」在学习 Agent 指令与 learning workflow 定义层。
3. **D4 不破**：网站无对话/执行页；富内容消费发生在 agent UI（扩展面板 + session），平台 Web 只做「地图」（报名前看什么）与「账本」（学到哪了）。

---

## 1. 领域术语（已同步 CONTEXT.md）

| 术语 | 取代 | 定义 |
|---|---|---|
| **issue（学习议题）** | section / story 卡 / 节 | 课程内容原子单元，User-Story 式内容契约；`kind: thoughtwork \| handwork` |
| **checklist（检查单）** | acceptance / 验收标准 | issue 内可自验条目清单 `{id, text}`；handwork 条目指向可检查产物 |
| **学习记录（LearningRecord）** | 验收回执 | 一条 checklist 条目的完成记录；个人记忆库原子数据；**挂人不挂报名**（Q1） |
| **goal（目标）** | goal / learning_objectives 混用 | 统一词汇：课程级 `goals[]`，issue 级 `story.goal` |
| **issue 状态** | 未开始/学习中/达成 | 与 Linear 同款 **Todo / In Progress / Done**，由学习记录**派生** |
| **kind（学习类型）** | （新） | `thoughtwork`（知识型，证据在对话）/ `handwork`（动手型，证据在产物）；平台只存标签不解释 |
| **issue key** | （新，已采纳） | 展示用短码（`PY-02` = 课程短码-序号），派生自 id 顺序，非存储字段 |

退役词汇：section、acceptance、learning_objectives、验收回执、story 卡（口语可留，代码/文档/测试一律用新词）。

---

## 2. 内容模型（issue 卡 schema 终稿）

```json
{
  "id": "py-first-program",
  "kind": "handwork",
  "title": "写你的第一个程序",
  "story": {
    "as_a": "刚装好 Python 的学员",
    "given": ["已完成 PY-01"],
    "goal": "独立写一个程序：问用户名字和年龄，存进变量，打印一句问候",
    "materials": [{ "title": "Python 官方教程 §5", "ref": "https://..." }],
    "checklist": [
      { "id": "c1", "text": "程序能在你的电脑上运行并正确输出" },
      { "id": "c2", "text": "能把代码逐行讲给别人听懂" }
    ]
  }
}
```

course content 整体（`get_course_content` 返回、ResearchOutput 存储）：

```json
{ "goals": ["能写简单程序", "理解基本数据结构"], "issues": [ /* issue */ ] }
```

设计纪律：

- **kind 二分**：thoughtwork / handwork 的分界线 = **证据在哪**（对话中的理解 vs 环境中的产物）。分级意义落在验收规则与教学循环（§6），**不落在材料形态**——materials 是朴素参考列表 `{title, ref}`，无 type 字段；动手卡 ≠ 技能，逐卡配技能会引爆教研工作量，平台不建模该耦合。
- **id 稳定纪律**：issue `id` 与 checklist `item_id` 一经发布不改不删；内容编辑保 id。学习记录永远可追溯 → 记忆导出的前提。
- **不引入正式内容版本号**（YAGNI）：靠 id 稳定纪律 + 学习记录引用 id，内容编辑不破坏进行中学员。
- goal 由 Tutor 设定（学员未必知道自己该学什么）；given 是先修状态描述，供 agent 对照学习记录判断起点。

---

## 3. 状态派生与进度投影

| 状态 | 条件（对某学员某 issue） |
|---|---|
| **Todo** | 无任何 `done: true` 的学习记录 |
| **In Progress** | 部分 checklist 条目 done |
| **Done** | 全部条目 done |

- 课程进度 = Done issue 数 / 总数。
- **learning run 完成语义升级（Q6）**：v1 学习定义极简化为**单 manual step 的协议容器**（学习循环整体，教学步骤不进 DAG——那是 agent 指令层的事）；run 完成完全由学习记录派生：全部 issue Done → run `succeeded`（取代现行「末个 manual step 的 facts 已写」，LearningProgressWorker 改判）。完成语义从「走完了」变为「学会了」。学习场景下 `save_step_output` 不再是主写路径（`save_learning_records` 取代）。
- **GraphQL 学习进度字段直接替换（Q13，不留兼容层）**：`completedManualSteps / totalManualSteps / currentStepTitle` → `doneIssues / totalIssues / currentIssueTitle`（+ issue key）；`LearningProgress.project` 的分子分母来源从 node_def/steps 切到 learning_records（耦合点：`web/lib/graphql/participations.ts` 的 MY_LEARNING_RUNS 字段与 `graphql_schema.ex` resolver 的 definition/node_def 加载链，一并改切）。
- 状态是投影不是手柄：Web / 面板只渲染，不提供手动切换（Linear 状态可拖拽，我们刻意不同——单一事实源是学习记录）。

---

## 4. 数据模型

### 4.1 教研产出（research_outputs，断链 #1 补齐，承载 issue 卡）

- 租户资源，唯一索引 `(key, kind)`（教研设计 §5.1 的落点）；`key = "course_<id>"`。
- v1 `kind = :issues`，`data` = §2 course content JSONB；`submitted_by`（Tutor）；`workflow_run_id` 关联教研 run。
- **写入通道（Q3）**：MCP 工具 `save_course_content`（显式写 ResearchOutput + 镜像教研 run facts）；`save_step_output` 只写 facts 不落业务表（代码事实证实），不是本链路的写入口。
- **活文档修订（Q8）**：run succeeded 后 Tutor 仍可经 `save_course_content` 随时更新内容（id 稳定纪律兜底进行中学员）；不需要新 run / 版本流 / 审核流（审核开关后置）。
- `kind = :materials`（招募物料）、`:archive`（归档）保留设计、实现后置（§9）。

### 4.2 学习记录（learning_records，新表）

| 列 | 说明 |
|---|---|
| workspace_id / course_id / **user_id** | 归属与租户 |
| issue_id / item_id | 追溯目标（id 稳定纪律） |
| done | boolean |
| evidence | text（一句证据摘要；handwork 条目 = 产物运行/检查结论） |
| recorded_at | 时间 |
| enrollment_id / run_id | **审计列**（记录当时哪个报名/哪个 run 写的，不参与唯一性） |

- **唯一键 `(course_id, user_id, issue_id, item_id)`，upsert 最新为准，不留历史版本**——记忆挂人不挂报名：退款取消报名后重报，记忆不清零。未来记忆导出若需历史再演进。
- policy：learner 本人读写；Web 本人可读。
- **课程终态读写策略（Q2）**：course close/cancel 后 `save_learning_records` 拒写（明确业务错误），读全保留（账本不删）；记录行永不动。
- **导出预留**：结构化行 + 稳定 id，未来 export 端点包一层皮；v1 不做端点，只保 schema 干净。

---

## 5. MCP 工具面（固定 8 → 12，两通道 CONTRACT.md 同步）

| 工具 | 参数 | 类别 |
|---|---|---|
| `get_course_content` | workspace_id, course_id | 读 |
| `get_learning_records` | workspace_id, **course_id 可选**（缺省 = 本人全部课程记录，课程列表由此推导） | 读 |
| `save_learning_records` | workspace_id, course_id, issue_id, records[]（item_id + done + evidence） | 写（直接写，不走两段确认） |
| `save_course_content` | workspace_id, course_id, content（§2 schema，校验 goals/issues 必填与 id 形态） | 写（直接写；授权 tutor ∪ owner/admin） |

- **授权与成员门槛（代码事实约束）**：学员是事件级参与者、**不是 workspace 成员**——学员侧工具（`get_course_content` / `get_learning_records` / `save_learning_records`）必须进 `Wrapper.@membership_deferred` 名单（同 `save_step_output` 先例），成员门槛延后到工具层，用「confirmed enrollment 本人 / 记忆持有者」判定（复用 `StepAuthorization.enrolled_learner?` 语义，身份锚 user_id）；写工具另校验 course 非 close/cancel。
- 契约影响：`backend/lib/cgc_2046/mcp/tools/` 一文件一工具（anubis_mcp 声明式注册，加行即可）；OpenClacky 扩展与 DSH `dsh-cgc-core` 的 CONTRACT.md「固定 8 工具」改为 12，两侧同步更新。
- 原计划中的 `get_learner_history` 语义并入 `get_learning_records`。

---

## 6. Agent 指令模板（算法在 agent）

### 6.1 学习 Agent 指令（八步循环，每次学习会话跑一遍）

1. `get_learning_records` → 学习记录（含在学课程列表）；
2. 选定课程后 `get_course_content` → issue 卡列表；
3. 扫描：全 Done → 跳过并告知；部分 Done → 记缺口；无记录 → 候选起点；
4. 第一个未 Done issue = 本次起点，向学员解释「为什么从这里开始」；
5. 教学循环，**按 kind 分支**：
   - **thoughtwork**：讲解 → 提问检验 → 纠正误解 → 再检验（苏格拉底式）；
   - **handwork**：agent 引导、**学员动手** → 遇阻协助调试 → 学员独立重做关键步骤（带练式；agent 代劳则 checklist 失效）；
6. **checklist 复盘**：逐条判定——**条目指向可检查产物时，必须实际运行/读取产物再判 done，不采信口头完成**；对话类条目经问答自验；
7. `save_learning_records` 写回；
8. 询问继续下一节还是休息 → 回到 3。

### 6.2 教研 Agent 指令（切片 1 同批产出）

从 `curriculum_requirements` + 与 Tutor 对话澄清 → 起草整套 issue 卡：User-Story 写法（as_a/given/goal）、checklist 可自验措辞（handwork 条目必须指向可检查产物）、kind 判别（证据在哪为界）、id 稳定纪律（修订保 id）→ 经 `save_course_content` 提交。

### 6.3 分发机制（算法如何到 agent）

① `WorkflowDefinition(type=learning)` 步骤骨架（版本化，v1 极简见 §3/§8）；② 学习/教研 Agent 指令（`get_agent_instruction`，D10 任务指令模式）；③ 可选本地 skill。**迭代算法 = 发布新版指令/定义，平台不发代码、零计算。** learning run 实例化链路不变（`enrollment.completed` → run，key = `enrollment_<id>`）。

---

## 7. 三块屏幕

```
平台 Web（薄）            扩展面板（学员主界面）      agent session（执行）
───────────────         ─────────────────        ────────────────
报名前地图、              课程导航台 +               教学对话、带练、
全局账本（进度）           当前 issue 卡 +            checklist 复盘、
                         checklist 打勾             学习记录写回
```

### 7.1 平台 Web

- **`/courses/[slug]` 课程地图**：story 骨架平铺 = issue key + 标题 + kind 标签（chip）+ **goal 一行**；**不露 checklist**（公开页职责是「承诺你会变成什么样」，评分细则不泄底；与 Linear 公开 roadmap 同构）。即招募文案本体。
- **`/participations` 我的学习**：顶部子导航「学习 / 报名 / 赞助」（模仿 Linear My Issues 的 Assigned/Created/Subscribed），学习为默认 tab。按**课程**分组；行 = 状态图标 + issue key + 标题 + kind 标签 + checklist 进度（n/m）。点击 issue → **右侧抽屉**（Linear 同款交互）：story 全文 + checklist 逐条（done / 未 + evidence 摘要 + 时间）+「在 OpenClacky 继续这一节」CTA（#92 OpenClackyCta 模式）。抽屉 = 学习记录在 Web 的账本展示面。
- **`/w/[slug]/courses/[id]` 管理页**补教研状态露出（run 状态 + issue 卡完成度）+ 教研需求自由文本框（落 curriculum_requirements，不做结构化表单）。
- 视觉：Tailwind 仿 Linear 设计语言（行密度、状态图标、标签、抽屉）。

### 7.2 扩展面板（v1 并入 cgc-2046；DSH 同构）

- **v1 并入 OpenClacky cgc-2046 连接器扩展**（panels 多面板机制，加 `panels/cgc-course/` 目录；将来独立分发 = 搬目录 + 改 manifest）。
- 面板结构：我的课程 → 课程 issue 列表（状态图标）→ 当前 issue 卡（goal / given / materials / checklist 打勾）→「和导师学这一节」→ 唤起学习 agent session（注入任务指令）。
- **数据通道**（dsh-cgc-core 已验证模式）：面板 → 扩展 loopback 路由 → 扩展 core 作为 MCP 客户端调 `get_learning_records` / `get_course_content` → JSON 渲染。面板是纯视图/导航，执行全在 session，记录写回后面板刷新。
- DSH 侧：`dsh-cgc-core`（独立仓库）加同构面板 + 路由，契约随 CONTRACT.md 同步。

### 7.3 Agent session

学习 agent 跑 §6 八步循环；面板与 session 经 harness 本地机制联动（subscribe / 会话 API），平台不参与。

---

## 8. 教研生产链（S1 升级 + 种子 + 完成机制）

- 教研 workflow **S1「Tutor 提交大纲」→「Tutor 提交 issue 卡集」**：输出 schema = §2 内容模型；信号改名 `research.outline.submitted` → `research.issues.submitted`（含幂等键前缀，不保留兼容）；产出经 `save_course_content` → ResearchOutput + facts 镜像（Tutor 与自己 agent 协作产出，平台不执行）。
- **生产时机**：开课前产完——issue 卡轻量化使门槛成立；「骨架先行/渐进产出」设计不需要。原「报名页露大纲」断链由 §7.1 课程地图承接。
- **`research_enabled` 语义分家（Q12，#90 以此关闭）**：
  - **Course：删列**。issue 卡是课程内容本体，恒走教研实例化，开关在 Course 上是死路径——migration 直接 drop `courses.research_enabled`；连带收紧：对账规则④的 course 分支去掉 `research_enabled` 过滤（**open 课程无 published 定义 = 无条件孤儿**，这现在真该报）、Readiness 教研项对 course 无条件检查。
  - **Event：保留**。语义定稿「这场活动不使用教研链路」（轻聚会退出通道）；UI 暴露留待真实需求。
  - **结构不动**：共享教研模板（教研设计拍板 #4 定义一次、Event/Course 参数化实例化——未翻案）、Offering seam、events/courses 表族全部保持；`ResearchInstantiator.ensure_research_enabled` 门控退化为 event-only 分支（本就按 key 前缀分叉）。教研设计 §1.3 默认值表随之被取代。
- **教研 run 完成机制（Q7）**：现状只有 reaper 取消、无 discharge（代码事实证实）。切片 1 加教研进度判定：`ResearchOutput(kind=:issues)` 已存在 → 教研 run 置 `succeeded`（`WorkflowRun :complete` 允许 running/waiting → succeeded 直达，状态机无障碍）。
- **双定义种子（Q14，对称极简）**：教研种子与学习种子同构——单 manual step 协议容器（教研 =「产出 issue 卡集」），完成由外部数据派生（ResearchOutput 存在 / 全 issue Done），seeds 落盘补断链 #5。教研设计的三段式 DAG（S0-S12）**降级为远期蓝图**，不在 v1 落地。
- **Readiness 语义**：有 published 教研定义即过（warn 放行）。

---

## 9. 范围与切片

**切片 1（本设计）**：

1. §2 schema 定稿 + §1 术语（已同步 CONTEXT.md）；
2. `research_outputs` 表（kind=:issues）+ S1 升级 + 信号改名 + 教研需求文本框；
3. `learning_records` 表（Q1 键设计）；
4. 4 个 MCP 工具（含 `save_course_content`）+ `@membership_deferred` 名单维护 + 两通道 CONTRACT.md 同步（8→12）；
5. 学习 Agent 指令模板（八步循环 + kind 分支 + 产物检查规则）+ 教研 Agent 指令模板 + 双定义种子（对称极简）；
6. LearningProgressWorker 完成语义升级（全 issue Done → succeeded）+ 教研 run discharge 判定；
7. GraphQL 学习进度字段替换（doneIssues/totalIssues/currentIssueTitle，Q13）；
8. `courses.research_enabled` 删列 migration + 对账规则④ course 无条件化 + Readiness course 无条件化（Q12）；
9. Web：课程地图 + 我的学习 tab + issue 抽屉 + 管理页教研露出；
10. 扩展：OpenClacky `panels/cgc-course/` + DSH 同构面板。

**后置**：教研聚合读工具（tutor 看学员掌握度、反哺迭代 issue 卡）、QnA 答疑段（教研设计 S7-S9）、`materials_review_required` 审核开关、`:materials`/`:archive` kinds、记忆导出端点、富记忆、kind 枚举扩展、Event 侧 research_enabled UI、三段式教研 DAG（远期蓝图）。

**相关 open issues**：#90 ✅（Q12 关闭）、#120（bus 重启不重订阅——实现期验证，不阻塞设计）。

---

## 10. 开放问题

| # | 问题 | 状态 |
|---|---|---|
| 1 | issue key（`PY-02` 式短码） | ✅ 已采纳（Q11-①） |
| 2 | Honeycomb = DSH | ✅ 已确认（Q11-③） |
| 3 | learning_records upsert 最新为准、不留历史 | ✅ 已拍板（Q11-②） |
| 4 | kind 枚举扩展（如 project 型大作业） | 真实需求出现再加 |
| 5 | `research_enabled` 开关处置（#90） | ✅ 已拍板（Q12：语义分家——Course 删列 / Event 保留） |
| 6 | 现行 manual-step 结构对极简化的约束 | ✅ 已核实并落 §3/§5（含 `@membership_deferred` 约束） |

---

## 11. 实施约束（代码事实锚点）

| 事实 | 锚点 | 对实施的约束 |
|---|---|---|
| WorkflowRun 无步骤持久化，steps 是 definition 侧投影 | `workflow_run.ex:141-149`、`run_steps.ex:32-44` | §3 极简化只动 definition 种子与 worker 判定，无 run 迁移 |
| `:complete` 允许 running/waiting → succeeded | `workflow_run.ex:341-356` | 教研 discharge 与学习完成均直接 `:complete` |
| 教研 run 现无任何 succeeded 生产路径 | `:complete` 全库仅 learning worker 调用 | Q7 worker 必须新增 |
| `save_step_output` 仅浅合并 facts、不写业务表 | `save_step_output.ex:87-108` | Q3 `save_course_content` 是 ResearchOutput 唯一写入口 |
| 学员非 workspace 成员，成员门槛在 Wrapper 层 | `wrapper.ex:30,72-82`（`@membership_deferred`） | 学员侧三工具进名单 + 工具层授权（§5） |
| anubis_mcp 工具注册纯声明式 | `mcp/server.ex:24-31` | 加工具 = 加一行 component，无数量耦合 |
| GraphQL 学习面字段与 resolver 加载链 | `participations.ts:119-134`、`graphql_schema.ex:1854-1945` | Q13 替换时同步改 `LearningProgress.project` 与加载链 |
| `research_enabled` 默认 true、消费方三处 | `event.ex:64-70` / `course.ex:63-69` / `reconciliation_scan_worker.ex:281-311` / `readiness.ex:30-32` | Q12 删列时三消费方 course 分支同步收紧 |

---

## 附：修订记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v0.1 | 2026-08-16 | 初稿（brainstorm 对话收敛） |
| v0.2 | 2026-08-16 | grill 第一轮 Q1-Q11 全部采纳落盘 |
| v1.0 | 2026-08-16 | **定稿：grill 第二轮 Q12-Q14 落盘**——Q12 换答案：`research_enabled` 语义分家（Course 删列恒走教研、Event 保留退出通道、结构不动，对账④/Readiness course 无条件化，#90 关闭）；Q13 GraphQL 进度字段直接替换为 issue 级（doneIssues/totalIssues/currentIssueTitle）；Q14 双定义种子对称极简、三段式 DAG 降级远期蓝图。新增 §11 实施约束（代码事实锚点：`@membership_deferred`、`:complete` 转移、声明式工具注册、GraphQL 耦合点） |
