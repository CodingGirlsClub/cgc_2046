# CGC 平台设计总纲（单一事实来源）

> **一句话定位**：本文件是 CGC 平台（Coding Girls Club，多租户社区协作平台）全部核心设计的**单一事实来源**；领域术语以根目录 [CONTEXT.md](../CONTEXT.md) 为准；更细的设计细节见 [docs/README.md](README.md) 分类导航。
> 版本：**v1.0** ｜ 日期：2026-08-01 ｜ 维护者：领域建模工程师（worker_f150e10b）＋ Leader 拍板
> 依赖定稿：`docs/01-定稿设计/领域模型定稿.md`（v1.1）、四份业务 workflow 设计（报名 v1.3 / 赞助 v1.1.1 / 邀请 v1.1 / 教研 v1.1）、`docs/04-引擎验证/workflow-engine-ddd-design.md` + `poc-验证报告.md`、`docs/03-决策记录/grill-决策记录-2026-08-01.md`（D1–D14 / D-A1–D-A7）
> **阅读约定**：本文件与定稿文档冲突时**以定稿文档为准**（见 §8 文档地图与「待核对」）。

---

## 1. 文档定位

- **本文件是什么**：把散落在各设计文档的核心决策收敛为一份可自洽阅读的「总纲」——面向未来接手的工程师/大模型，读这一份即可建立平台全貌；细节按 §8 文档地图回查原文。
- **本文件不是什么**：不替代 CONTEXT.md（术语权威）、不替代领域模型定稿（实体/ER 权威）、不替代 workflow 详细设计（步骤级权威）、不引入新决策。
- **一致性与冲突处理**：总纲只收敛、不新增决策；若发现总纲与定稿文档矛盾，记入 §8「待核对」并汇报 Leader 定夺，**不自行改定稿文档**。
- **术语纪律**：本文引用术语全部对齐 CONTEXT.md；如需新术语，列入 §8「术语待办」建议更新 CONTEXT.md。

---

## 2. 架构总览

### 2.1 一句话架构

> **网站 = 业务中枢 + MCP server；用户自带 OpenClacky 做 Agent 执行（BYO，自带模型）；业务编排由网站侧 Jido workflow 引擎做确定性编排（workflow-first）。**

- **BYO（D1/D3/D5/D6）**：网站不跑 LLM/ToolLoop，零 AI 成本；用户侧 OpenClacky 经 B 通道（唯一对外通道）调用网站暴露的**一个** MCP server（anubis_mcp）。用户离线则该用户 Agent 任务不可用（接受，D3）。
- **workflow-first（D-A1/ADR-0002）**：核心模型 = **WorkflowDefinition（DAG 蓝图）+ WorkflowRun（执行实例）**；引擎 = Jido 生态（jido + jido_runic + ash_jido + jido_signal），Runic alpha 锁版本 + 适配层隔离。引擎只做**确定性编排**，不承担 LLM 推理（§4.7 与 BYO 不矛盾）。
- **同步/异步 8:2（D-A6）**：业务核心状态主写走 ash_jido 同步 Action（强一致，约 8 成）；衍生副作用/跨 context 通知走 Signal 异步最终一致（约 2 成）。

### 2.2 架构分层图

```mermaid
flowchart TB
    subgraph 用户侧["用户侧（BYO，用户自带）"]
        OC["OpenClacky"]
        EXT["连接器扩展 cgc-2046<br/>（自动配置 mcp.json / 同步 Skill / CGC 助手）"]
        OC --- EXT
    end

    subgraph 网站侧["网站（业务中枢 + MCP server + workflow 引擎）"]
        subgraph 业务资源["业务资源（Ash，tenant_id 隔离）"]
            U[User / Workspace / Role]
            E[Event / Course]
            ENR[Enrollment / Sponsorship / SpeakerInvitation / InviteBatch / ResearchOutput]
        end
        subgraph 引擎["Workflow 引擎（Jido 生态）"]
            DEF[WorkflowDefinition<br/>platform_ops|learning|enrollment|sponsorship|speaker_invitation|research]
            RUN[WorkflowRun<br/>pending→running→waiting→succeeded/failed/cancelled]
            STEP[Step 四分类<br/>自动/人工/门控/子 workflow]
            PART[partition = Workspace]
            TJ[Thread journal 审计]
            DEF --> RUN
            RUN --> STEP
            RUN -.归属.-> PART
            RUN -.审计.-> TJ
        end
        MCP["MCP server（anubis_mcp）<br/>读 / 写 / 管理类 + 确认流"]
        MCP --> 业务资源
    end

    OC -- "B 通道（唯一对外通道）<br/>MCP JSON-RPC over HTTP/SSE" --> MCP
    MCP -- "Signal 放行 / 读产物" --> 引擎
    引擎 -- "同步调 Ash Action（8 成）" --> 业务资源
    引擎 -- "异步 Signal（2 成）" --> 业务资源
```

- **依赖方向恒为 workflow → 业务 Action 接口**（D-A1/草案 B）：业务 context 反向只发 Signal、不调引擎。
- **MCP 作用域（D12）**：所有 MCP 工具必填 `workspace_id`（无状态、每调用鉴权 + 审计）；「当前工作区」由用户侧 CGC 助手维护，服务端不存会话状态（MCP client 是 server 级全局长连接，存状态会跨会话串）。
- **租户模型（D-A5）**：一个 Workspace = 一个 Jido partition；共享表 + tenant_id（Ash attribute 多租户），不走 schema-per-tenant。

---

## 3. 核心领域模型摘要

> 实体/ER 权威：`docs/01-定稿设计/领域模型定稿.md` §5；术语权威：CONTEXT.md。

### 3.1 实体清单表（关键实体）

| 实体 | 一句话 | 归属 context | 关键字段 |
|---|---|---|---|
| User | 全局账号，一人多 Workspace | 全局 | email、is_platform_admin |
| Workspace | 组织单元/租户单元 | 全局 | slug（唯一）、join_policy（open\|request\|invite_only）、sponsorship_enabled；**UI 展示需区分策略三态与成员中间态（原型验证结论 #1）** |
| WorkspaceMembership / MembershipRole / Role | 成员关系 + N:M 多角色；角色为可扩展实体 | 身份/租户 | 默认模板 Owner/Admin/Tutor/Volunteer/Learner；**成员中间态：request 策略申请中 → pending（JoinRequest）；invite_only 已受邀 → invited（Invitation）**；**角色扩展注记（2026-08-02 拍板）：切片 A 阶段角色为平台统一六模板（owner/admin/member/tutor/volunteer/learner），「自定义角色」为未来能力，当前不做（无真实差异化需求 + 保留静态 RBAC 简化）；触发条件 = 出现真实工作区角色差异化需求（预计 workflow 定制场景，F 切片之后）；届时增量落地：permissionMatrix(workspaceId) 租户查询 + Role 能力配置 + 动态判定，登记于 GitHub backlog** |
| Invitation / JoinRequest | 加入 Workspace 的邀请链接 / 加入申请 | 身份/租户 | token_hash、expires_at、status；join_policy=request 时审批 |
| WorkflowDefinition | DAG 蓝图（可复用、带版本） | 引擎 | type、version、input_schema、node_def（Runic.Workflow）、**approval_timeout**（审批超时，默认 7 天，可配置，null=无超时，F7 方案 A） |
| WorkflowRun | DAG 执行实例 | 引擎 | status、input_snapshot、facts、signal 日志、partition_id（=workspace_id） |
| Step | DAG 节点（四分类） | 引擎 | type（auto\|manual\|gate\|subworkflow）、agent_id、sub_definition_id |
| SignalLog | 收到的外部信号日志 | 引擎 | signal_type、payload、actor_id |
| Agent / AgentRun | 授权/配置登记（非执行实体）/ 按 Step 聚合的操作记录 | Agent/MCP | type（personal\|public）、allowed_roles；AgentRun 由网站自动生成（D9） |
| PendingOperation / ToolCallLog | 确认流 pending / MCP 工具调用审计 | Agent/MCP | tool、params、status；无 confirm 不落业务库（D8） |
| Event / Course | 活动（场地形态）/ 线上课程，挂 Workspace 下 | 业务 | enrollment_policy、capacity、registration_deadline、status；EVENT 另含 sponsorship_enabled/sponsorship_deadline；均含 materials_review_required（默认 false） |
| Enrollment | 事件级报名（不自动成为成员） | 业务 | status（pending\|confirmed\|rejected\|**expired**\|cancelled）、invite_batch_id、approved_by/approved_at |
| InviteBatch | invite_only 凭据 = 共享批次码 + quota | 业务 | invite_code（唯一）、quota、remaining_quota、expires_at |
| Sponsorship / SponsorshipTier | 两级赞助（Event 级 + Workspace 级）/ Workspace 档位配置 | 业务 | level（event\|workspace）、tier_id、status（pending\|active\|rejected\|**expired**\|ended）；TIER: benefits 权益项、limit（二期预留） |
| SpeakerInvitation | Event 级逐人演讲邀请（分享完关系结束） | 业务 | token_hash（一次性）、speaker_user_id（接受后绑定）、status（invited\|accepted\|declined\|completed） |
| ResearchOutput | 教研产出（大纲/材料/归档） | 业务 | key（event_#\|course_#）、kind（outline\|materials\|archive）、唯一索引 (key, kind) |

### 3.2 状态机摘要

| 实体 | 状态机 |
|---|---|
| WorkflowRun | `pending → running → waiting（人等信号，hibernate） → succeeded / failed / cancelled` |
| WorkflowDefinition | `draft → published → archived`（改定义不影响已开始 run） |
| WorkspaceMembership（含中间态） | **join_policy 三态（open/request/invite_only）与成员中间态需在 UI 上区分展示（原型验证结论 #1）**：request → 申请后显示「申请审批中」（JoinRequest pending），审批通过才成为成员；invite_only → 受邀后显示「待凭据加入」（Invitation invited），凭据校验/确认后成为成员；open → 直接成为成员（无中间态）。不能只显示三态徽章 |
| Enrollment | `pending（request 策略） → confirmed / rejected / expired（审批超时自动失效，≠ rejected，可重提）/ cancelled`；open/invite_only 直接 confirmed |
| Sponsorship | `pending → active / rejected / expired（审批超时自动失效，≠ rejected，可重提）/ ended`（Event 级随 Event 结束自动 ended） |
| SpeakerInvitation | `invited → accepted / declined → completed`（expired 可选） |
| InviteBatch | `active / disabled`（quota 原子扣减） |

### 3.3 WorkflowDefinition.type 枚举（统一，Leader 拍板）

`platform_ops | learning | enrollment | sponsorship | speaker_invitation | research`

- 四份业务 workflow 对应：报名=**enrollment**、赞助=**sponsorship**、邀请=**speaker_invitation**、教研=**research**（原 `invitation`→`speaker_invitation`、`teaching_research`→`research` 已统一，见领域模型定稿 §9）。

---

## 4. 业务 workflow 四件套

> 每份权威：`docs/01-定稿设计/XXXworkflow详细设计.md`；本节只给一句话目标、主路径、关键机制、开放问题现状。

### 4.1 报名 Workflow（v1.3 定稿）— type=enrollment

- **一句话目标**：Learner 报名 Event/Course，同步创建 Enrollment（强一致：名额/唯一性；D-A4），不自动成为成员。
- **主路径 DAG**（§2.1）：报名段 `表单提交(S1,信号门控) → 输入校验(S2) → 策略路由(S3) → [open]名额检查(S4) / [request]persist_pending(P1,停住等审批) / [invite_only]邀请凭据校验(S6) → create_enrollment(S7,ash_jido 同步) → 发 enrollment.completed(S8)`；`request` 另走**审批段**（独立审批段，审批两段式）：`审批信号门控(A1) → approval_gate 读回 pending(A2) → confirm_enrollment(A3) / 置 rejected(A4)`。
- **关键机制**：`open` v1 主路径单段即可；`request` 必须**审批两段式**（业务异步审批需要 + Agent 策略层 join 死锁缺陷未修复前的架构层规避；v1 主路径 Workflow 层原生无缺陷）；`invite_only` 凭据 = **InviteBatch 共享批次码 + quota**（§3.6，拍板 #4）；审批入口 = **网站后台审批页**（§3.5，拍板 #3，非 MCP 管理类、不复用 D8 确认流）；幂等三层（request_id + 业务唯一索引 + signal idempotency_key，承载 Postgres/Redis）；**审批超时（F7 方案 A，v1.4 定稿）** = `approval_timeout` 默认 7 天（可配置，null=无超时）→ pending 转 `expired`（终态，≠ rejected，可重提）；deadline 前 48h 提醒审批人；过期后申请者可重新提交（新 run，request_id 区分，幂等不冲突）。
- **开放问题现状**：✅ 14 项 ｜ 🟡 1 项（#5-② deadline 到点唤醒 → cancel 路径，v1 联调期补测）｜ 🔶 0。

### 4.2 赞助 Workflow（v1.1.1 定稿）— type=sponsorship

- **一句话目标**：Sponsor（非成员全局账号）发起两级赞助（Event 级单场 / Workspace 级长期），审批后权益生效；v1 只做意向+审批+权益生效、**不收款**（§3.3 资金边界，支付二期）。
- **主路径 DAG**（§2.1）：赞助段 `意向提交(S1,信号门控) → 校验(S2) → persist_sponsorship(P1) → 停住等审批` → 审批段 `审批信号门控(A1) → approval_gate(A2) → activate_sponsorship(A3,同步) → 发 sponsorship.active(A5,异步 → 权益生效)`；与报名 request 同构（§8 模板复用）。
- **关键机制**：权益 = Workspace 配置 **SPONSORSHIP_TIER**（名称/建议金额/权益项列表：logo 展示位、报名页露出、鸣谢页、现场物料位；拍板 #3），Sponsorship 关联 tier_id；v1 不限额（tier.limit 预留二期，拍板 #1）；审批权限 = Workspace 级**仅 Owner**、Event 级 Owner/Admin（拍板 #4，平台 Admin 备案二期）；审批入口 = 网站后台审批页（赞助管理，同报名 #3 决策）；**审批超时（F7 方案 A，赞助 v1.2 修订）** = `approval_timeout` 默认 7 天（可配置，null=无超时）→ pending 转 `expired`（终态，≠ rejected，可重提）；deadline 前 48h 提醒审批人；过期后赞助方可重新提交（新 run，request_id 区分，幂等不冲突）。
- **开放问题现状**：✅ 9 项 ｜ 🟡 1 项（#5 终止/续期 workflow 化，v1 细化）｜ 🔶 0。

### 4.3 邀请 Workflow（v1.1 定稿）— type=speaker_invitation

- **一句话目标**：Owner 创建 Event 级 SpeakerInvitation（逐人定向），Speaker 接受/拒绝 → 接受后产出分享材料 → 分享完关系结束（不成为成员）。
- **主路径 DAG**（§2.1）：邀请段 `create_invitation(S1,同步) → 接受/拒绝信号门控(S2) → [accepted]accept_invitation(A1) → produce_materials(M1,材料产出) → 发 speaker.completed(M2,异步)`；`[declined]decline_invitation(R1)` 直接终态。
- **关键机制**：凭据 = **逐人 token（一对一、一次性，accept/decline 后失效）**，区别于报名 invite_only 的共享批次码（§3.3 对比）；**Speaker 必须全局账号**（接受时注册/登录硬约束，拍板 #1）；v1 **不拆独立分享 workflow**（材料产出内嵌 M1，落 WorkflowRun.facts，保留 speaker.accepted 扩展点，拍板 #4）；材料产出经用户侧 `save_step_output`。
- **开放问题现状**：✅ 7 项 ｜ 🟡 1 项（#2 邀请过期未决策处理，v1 细化）｜ 🔶 0（#3 批量邀请、#5 Workspace 级讲师为**二期**）。

### 4.4 教研 Workflow（v1.1 定稿）— type=research

- **一句话目标**：Tutor 为 Event/Course 产出教研材料（大纲/招募物料/答疑），配合现场辅导；**核心 = 定义一次、被多个 Event/Course 实例化复用（D-A2）**。
- **主路径 DAG**（§2.1，三段式模板）：教研产出段 `ResearchInit(参数注入) → Tutor 提交大纲(S1) → save_outline(S2) → 提交招募物料(S3) → save_materials(S4) → 审核门控(S5) → [需审核]Owner 审核(S6) / [免审核]跳过` → 现场辅导段 `open_qna(S7) → 答疑交互循环(S8↔S9)` → 收尾段 `归档/复盘(S10+)`。
- **关键机制**：**定义-实例化**（verify_8 D-A2a PASS）= WorkflowDefinition ↔ Agent module + workflow_fn 模板，InstanceManager keyed singleton（key = event_# / course_#）→ 一个定义 N 个 run 零引擎改动；**参数化**（D-A2b）= run input（signal data → fact → ActionNode params）注入，Action schema 声明 course_id/event_id 必填，**无占位符替换机制**；审核**默认关闭、可配置启用**（materials_review_required 默认 false，启用时复用网站后台审批页、打回重提，拍板 #2）；现场辅导 **v1 不拆独立 run**，Tutor 介入 = workflow 内门控决策点（自动应答置信度低/学员点名/复杂问题 → 转人工 research.answer，判定规则 v1 细化，拍板 #3）。
- **开放问题现状**：✅ 9 项 ｜ 🟡 1 项（#8 答疑交互模式判定规则，v1 联调期细化）｜ 🔶 0。

---

## 5. 引擎可行性结论（verify_1..8 全 PASS）

> 权威：`docs/04-引擎验证/poc-验证报告.md`；版本：elixir 1.20 / jido 2.3.2 / jido_runic 1.0.0 / ash_jido 1.0.0 / runic ~> 0.1.0-alpha.4 / jido_signal 2.2.2。

### 5.1 POC 结论一览（一行一个）

| # | 验证项 | 结论 |
|---|---|---|
| verify_1 | jido_runic DAG 执行（报名简化版） | ✅ PASS：三节点线性 DAG、同步写 ETS 立即可读、数据流传递正常 |
| verify_2 | 人工步骤 SignalMatch 门控（waiting + 信号放行） | ✅ PASS：Workflow 层 join 双信号分步 feed 正常；**Agent 层暴露 ran_nodes 缺陷**（见 5.3），审批两段式（Agent 层缺陷规避手段）PASS |
| verify_3 | ash_jido 同步写（Enrollment 约束检查） | ✅ PASS：同步写/立即可读/约束/唯一拒绝；⚠️ Ash 3.31 业务字段需 `public?: true` 才进输出 |
| verify_4 | 异步 Signal 订阅（enrollment.completed → 衍生动作） | ✅ PASS：Signal Bus 异步投递 + signal_routes 路由触发衍生动作 |
| verify_5 | partition 多租户隔离 + Thread journal 审计溯源 | ✅ PASS：同名 Agent 跨 partition 不冲突、数据隔离、instruction_start/end 审计配对完整 |
| POC-2 G1 | waiting 持久化 hibernate/thaw（A1–A5） | ✅ PASS：checkpoint + thread pointer rev 校验，恢复期间信号不丢不重，循环 2 周期正确 |
| POC-2 G2 | Bus journal 重放 + 幂等（B1–B3） | ✅ PASS：无订阅者 publish 入 journal；重启后 replay 补齐；同 idempotency_key 重复投递只执行一次 |
| verify_8 | D-A2 定义一次多实例复用（D-A2a–D-A2d） | ✅ PASS：Agent module + InstanceManager keyed singleton 天然支持；参数化靠 run input 注入；实例级隔离；生命周期三段闭环 |

### 5.2 D-A2 映射（定义复用）

- **Agent module ↔ WorkflowDefinition**（模板）；**InstanceManager key ↔ WorkflowRun**（实例，key = event_id/course_id）。
- 生命周期：`event.launched` 信号 → 应用层订阅 → `InstanceManager.get` 实例化（幂等）；idle 超时 hibernate；`event.ended` → stop 回收。
- **对设计的影响**：教研 workflow 直接落地此机制；报名/赞助/邀请未来「模板化」可反向参考（同一报名表单多活动复用）。

### 5.3 已知缺陷与绕行（生产必须遵守）

1. **jido_runic 1.0 Agent 策略（auto）ran_nodes 过滤缺陷**：同一 workflow 内 join 等**两个以上异步信号**会死锁（feed1 后 join 进 ran_nodes，feed2 满足条件却被过滤）。**定性（F1 落账升级，2026-08-01）**：缺陷仅存在于 **jido_runic Agent 策略层**（`strategy.ex` `handle_apply_result` 无条件 put ran_nodes），**非 runic 引擎缺陷**——**v1 主路径固定 Workflow 层（runic 直接驱动）本身就是 jido 原生能力，非绕行**（原生 runner 无 ran_nodes 概念，靠图边状态驱动，join 每次 fact 到达都会重新 prepare → 无死锁）；审批两段式仅为 Agent 策略场景下的架构层规避手段（业务异步审批需要 + 缺陷未修复前规避；分段 + 持久化 pending，如报名 request / 赞助）。Agent 层不得用单 DAG join 等双信号。适配层必须内置「多信号分批 feed」集成测试防回归。**二期根治已定位**：上游提交 ran_nodes 修复 PR（一行级，`result==:waiting` 不进 ran_nodes，修复方案 POC 已验证）；Agent 层标准写法采用官方 Coordinator fan-in（orchestration guide 先例，POC 已验证）。
2. **ETS 幂等键 owner 陷阱**：幂等去重表由 action 执行进程自建 ETS 会随进程退出销毁 → 幂等失效（B3 一度 FAIL）。**生产幂等键用 Postgres 唯一约束（signal_idempotency 表）或 Redis（SETNX/EXPIRE），不用 action 进程自建 ETS**；ETS 仅限 dev/test 且 owner 为长生命周期进程。

---

## 6. 通用机制模式库

> 四份 workflow 共享的成熟模式，新增业务 workflow 时直接复用（出处见各文档 §8 横向复用点）。

| 模式 | 说明 | 出处 |
|---|---|---|
| 审批两段式 | 含两个人工信号（如报名+审批）必须拆段：第一段 persist_pending 停住，第二段 approval_gate 读回持久化结果再确认（业务异步审批需要；Agent 策略层 join 死锁缺陷未修复前的架构层规避） | 报名 §3.2 / 赞助 §2.1（POC §3.4 PASS） |
| 实体自序贯 | 单 context 状态机 + DB 已强制全部并发不变量 + after_transaction 信号可达全部订阅方时，workflow 默认不引擎化：资源行即 pending checkpoint，信号经 action after_transaction 直发订阅方；引擎化需证成（跨角色编排 / 多实例复用 / 分支或子 workflow 拓扑 / 超出实体 policy 的分步授权）；审批入口仍为网站后台审批页 | ADR-0005（报名先例；backend/lib/cgc_2046/events/enrollment.ex） |
| SignalMatch 门控 | 人工步骤 = 按 signal type 前缀门控下游；人触发的是「恢复」而非「启动下一段」 | 报名 §3.1（verify_2 PASS） |
| hibernate/thaw | waiting 落 checkpoint 休眠，信号到达 thaw 恢复；长等待不占资源 | POC-2 G1 PASS（报名 §3.3） |
| signal_idempotency | 异步副作用幂等键承载 = Postgres 唯一约束 / Redis；勿用 action 进程 ETS | POC-2 G2 B3（报名 §4.3） |
| Thread journal 审计 | 引擎审计流 = append-only journal + Checkpoint + 溯源链；与 ToolCallLog/AgentRun 互补 | verify_5 PASS（领域模型 §8） |
| 网站后台审批页 | 业务审批（报名/赞助/教研材料）统一入口 = 网站后台审批页，非 MCP 管理类、不复用 D8 确认流 | 报名 v1.3 §3.5（拍板）→ 赞助/教研复用 |
| 三种凭据/名额机制 | ① 报名 invite_only：InviteBatch 共享批次码 + quota（一对多，原子扣减）；② 赞助 tier.limit：二期预留（限量复用配额扣减）；③ Speaker 邀请：逐人 token（一对一、一次性） | 报名 §3.6 / 赞助 §7 #1 / 邀请 §3.3 |
| 材料产出落点 | Step 产物落 WorkflowRun.facts，经用户侧 `save_step_output` 保存；网站只读展示（形态 X） | 邀请 M1 / 教研 §5.1 |
| 同步 8 / 异步 2 | 核心状态主写走 ash_jido 同步 Action（强一致）；衍生副作用/通知走 Signal 异步最终一致 | D-A6（POC 验证项 3/4 PASS） |

---

## 7. 实施路线

> 权威：`docs/01-定稿设计/技术调研与实施计划.md`（端到端 TDD 实施计划，M0–M4）。

### 7.1 里程碑总览

| 里程碑 | 内容 | 说明 |
|---|---|---|
| M0 | 地基：User/Workspace/Role/Membership/Rbac/JoinRequest/Invitation/Profile | 后端先行，无 MCP |
| **M1** | **Workflow 引擎（workflow-first，教研场景）**：WorkflowDefinition/WorkflowRun/Step 四分类/人工步骤 waiting + 信号放行/StepRole/教研学习双 workflow 实例化 | **当前核心里程碑**；依赖 POC 结论已全 PASS，可进入实现 |
| M2 | 网站 MCP server（anubis_mcp）+ 连接器扩展 cgc-2046（BYO 大改）：工具集/确认流/AgentRun 审计/Skill 同步/Onboarding | 依赖 M1 |
| M2.5 | 业务 workflow 切片：报名（同步建 Enrollment）/ 异步 Signal / 赞助（两级）/ 邀请（Speaker） | 依赖 M1 + M2 |
| M3 | 前端页面（Next.js，形态 X 无对话/执行页）：登录/工作台/Event 报名页/赞助页/连接引导/审计查看 | 依赖 M2.5 |
| M4 | 集成验证 + 越权演练 + 手工端到端 | — |

### 7.2 剩余 🟡 待办（v1 联调期细化）

| 项 | 内容 | 出处 |
|---|---|---|
| 报名 #5-② | deadline 到点唤醒 → cancel 路径（恢复时检查 deadline → Emit cancel 或 Schedule Directive），补集成测试 | 报名 §7 #5 |
| 邀请 #2 | 邀请过期未决策 → run cancelled + status=expired（复用 deadline 唤醒模式） | 邀请 §7 #2 |
| 教研 #8 | 答疑交互模式：自动应答 vs Tutor 人工介入判定规则（置信度阈值/学员点名）、多轮 hibernate/thaw 压测 | 教研 §7 #8 |
| 赞助 #5 | Workspace 级赞助终止/续期入口与 workflow 化 | 赞助 §7 #5 |
| 生产压测 | 名额原子扣减/唯一约束的 Postgres 锁粒度（G3，ETS 逻辑已验） | poc-验证报告 §11 |
| M3 前端约束 | **PROTOTYPE 浮动栏生产隐藏（原型验证结论 #5）**：原型专用浮动栏在生产构建（M3）自动隐藏/移除，正式版不出现 | 用户旅程与Web功能清单 §3 说明 |
| 其它 | Invitation 撤销流程、JoinRequest 角色分配方式、PendingOperation 过期清理、确认流 auto_approve **v1 默认关 / 仅限白名单工具（F8），白名单外必须人工确认；冷却期二期** | 领域模型 §5.3 / CONTEXT §10 |

### 7.3 二期清单

支付（赞助 #2：状态机插 payment_pending → paid）、批量邀请候选池（邀请 #3：复用 InviteBatch quota 机制）、Workspace 级讲师/长期嘉宾（邀请 #5：成员/合作关系建模）、tier 限量（赞助 #1：启用 tier.limit 校验）、平台 Admin 备案（赞助 #4）、通用审计聚合/导出（ash_paper_trail）、确认流 auto_approve 冷却期。

---

## 8. 文档地图与待核对

### 8.1 什么场景读哪份

| 场景 | 读什么 |
|---|---|
| 先建立全貌 | **本文件（00-CGC平台设计总纲.md）** |
| 术语定义 | 根目录 **CONTEXT.md**（唯一术语事实源） |
| 实体/ER/状态机/权限矩阵 | `docs/01-定稿设计/领域模型定稿.md` |
| 报名/赞助/邀请/教研步骤级设计 | `docs/01-定稿设计/报名workflow详细设计.md`（v1.3）/ 赞助（v1.1.1）/ 邀请（v1.1）/ 教研（v1.1） |
| 实施里程碑/技术选型 | `docs/01-定稿设计/技术调研与实施计划.md` |
| 9 项开放问题拍板记录 | `docs/01-定稿设计/开放问题决策清单.md` |
| 用户旅程/Web 功能清单 | `docs/01-定稿设计/用户旅程与Web功能清单.md` |
| 引擎可行性/POC 实证 | `docs/04-引擎验证/poc-验证报告.md` + `workflow-engine-ddd-design.md` |
| 决策依据 | `docs/03-决策记录/grill-决策记录-2026-08-01.md` + `docs/adr/` |
| 文件导航 | `docs/README.md` |

### 8.2 待核对（当前无）

- 总纲撰写时未发现与定稿文档的矛盾；如后续发现，在此登记并汇报 Leader。

### 8.3 术语待办（当前无）

- 总纲未引入新术语；若后续需要，建议更新 CONTEXT.md（由文档修订工程师执行）。
