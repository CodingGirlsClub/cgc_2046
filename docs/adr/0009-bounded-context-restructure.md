# ADR-0009: 限界上下文重构——Events/Courses 分家、Admission 独立、Curriculum 命名

> 日期：2026-08-28 ｜ 状态：**已接受（Accepted）· 实施完成（2026-08-28，更正后五步 PR 序列全部合入）** ｜ 决策者：用户（product owner）
> 关联：ADR-0007（缴费架构）、`docs/01-定稿设计/领域模型定稿.md` §5.4、CONTEXT.md；缘起：`backend/lib/cgc_2046/events/course.ex` 归属质询引发的架构讨论（2026-08-28）
> 方法依据：DDD 事件工作坊方法（事件风暴 → 命令风暴 → 寻找聚合 → 划分边界；边界三判据 = 聚合/业务相关性/概念完整性；上下文映射七关系）对现有代码的实证分析

---

## 背景（Context）

- `events/` 目录是整个「业务」context 的倾倒场：Event、Course、Enrollment、InviteBatch、Sponsorship（含 Delivery/Tier）、SpeakerInvitation 六个**变化原因不同**的聚合群被「都挂在活动上」一个理由捆在一起（D-A4「Enrollment 归活动 context」的直接后果）。
- Course 与 Event 当前字段同构、共享报名/定价/时序机制，但两者的迭代重心已分叉：Course 侧在长内容形态与学习闭环（issue 卡集、checklist、LearningRecord、MCP 学习工具），Event 侧在长运营能力（场地、赞助权益、嘉宾邀请）。
- 平台已部署但用户量仅 product owner 一人，**可接受重置数据库**——允许「模型先行、整体切换」的大胆重构，无需绞杀式迁移与数据迁移。
- 现成插桩点：`Cgc2046.Events.Offering`（供给物读取 seam，plan 2026-08-15-009）、`payments/orders.enrollment_id` 裸 UUID 软引用（无 DB 外键，order.ex admin 查询已按 event/course 分叉 JOIN）、对账 Finding 底座（ReconciliationScanWorker + PaymentReconciliationWorker 共用 reconciliation_findings 表与刷新语义）。

## 分析（事件风暴重跑，代码实证）

**领域事件清单**（信号契约即事件，`SignalEmitter` + subscriber patterns 实证）：

```
course.launched / course.ended        → 教研实例化、分享码预生成、退款扫描、教研 run 收割
event.launched / event.ended          → 同上 + 赞助级联结束
enrollment.submitted/approved/rejected/completed → 通知、学习 run 实例化
order.paid                            → 落账（enrollment confirmed）
sponsorship.submitted/approved/rejected/active
```

**判据应用**：

1. **Persona 分叉**（工作坊 slide 25：利用 persona 判断聚合）——课程侧主角色 = Tutor（教研）+ Learner（学习闭环）；活动侧 = Owner（运营）+ Speaker + Sponsor + Volunteer。两线主角色集合几乎不相交 → 支持 Events/Courses 分家。
2. **变更频率分叉**（服务划分原则二）——Course = 内容形态与学习闭环；Event = 运营（场地/赞助/嘉宾/现场）。同一目录使两类变更永远互相搅扰 review 与回归面 → 支持分家。
3. **统一语言检验**——`enrollment.submitted/approved/completed` 对 Event 与 Course 语义逐字相同，是**同一个概念**；拆成 EventEnrollment/CourseEnrollment 会一词两义。报名与两侧的业务相关性完全对称 → 不属于任何一侧，提升为独立限界上下文（Admission）。

## 决策（Decision）

### 目标限界上下文地图

```
Identity/Tenancy (supporting) —— User, Workspace, Membership, Role, Invitation, JoinRequest, Profile
  │ OHS（身份/租户是全域上游）
  │
Events (core)                Courses (core)
  Event, Venue                 Course（供给：排期/定价/报名策略/发布状态）
  SpeakerInvitation            └─ 内容发布投影（引用 Curriculum 产出）
  │
  │   OHS + Published Language（Offering 供给物读契约：status/capacity/deadline/price_tiers）
  ▼
Admission (core) —— Enrollment, InviteBatch, 名额账本
  │ Customer/Supplier
  ▼
Payments (supporting) —— Order, Provider（ACL → 微信/支付宝）, 资金对账 worker

Curriculum (core，教研) —— 教研产出物（outline/materials/issues/archive）起草/审核/归档
  │ 被 Events/Courses 实例化引用；被 Learning 读契约消费

Sponsorship (core) —— 两级赞助（Event 级/Workspace 级）+ 履约账本
Learning (core) —— LearningRecord（记忆挂人）、进度投影
Workflows (generic) —— WorkflowDefinition/WorkflowRun/Step、信号总线
Notification (supporting) —— Fanout/Service/Templates
Platform Reporting (supporting) —— Reconciliation Finding 底座（各域扫描器写入）
MCP gateway (interface layer) —— 工具面/鉴权/审计（适配器，不含领域逻辑）
```

### 分项决策

1. **D1：Admission（报名）独立限界上下文。** Enrollment + InviteBatch 迁入；enrollments **保持单表不复制**；Events/Courses 是其上游。取代 D-A4「Enrollment 归活动 context」。
2. **D2：名额账本归 Admission。** offering launched 信号到达时建 capacity 投影；占位/释放的原子 CAS 在 Admission 自己的账本表内进行（超卖防护不变甚至更强）；offering 上的 `confirmed_count` 退化为**展示投影**，信号最终一致同步。消除系统唯一的跨 context 写点（今天 Enrollment 创建事务里对 `events/courses.confirmed_count` 的条件 UPDATE）——**更正补记（2026-08-28 实施期）**：「唯一」实为三处——enrollment.ex reserve / release 两处裸 SQL 条件 UPDATE、order.ex expire 链的名额回落、events/courses 上 confirmed_count check constraint 与账本语义的耦合；三处均已在 PR⑤ 收编进名额账本。落实「服务独占自己数据的更新权」。已知代价：capacity 调小后存在信号同步窗口期的理论超卖风险，由账本侧 CAS 兜底拒单 + 对账规则兜底。
3. **D3：内容归 Curriculum（教研）context，Course 持发布投影。** 教研产出物（现 `ResearchOutput` 家族：outline/materials/issues/archive）的起草/审核/归档归 Curriculum；Courses 拥有课程供给（排期/定价/报名策略/发布状态）与「哪版内容已发布」的投影；Learning 经读契约消费已发布内容。物理基础已存在（内容本体存 ResearchOutput，`course_content/1` 本为读 seam）。
4. **D4：Sponsorship 独立 context。** 两级赞助（Event 级单场 / Workspace 级长期）+ 履约账本，不纯是 Event 的附属；Event 引用改软引用。
5. **D5：Offering 保留命名、转正为发布语言读端口。** 英文标识符不动（`Cgc2046.Offering`，移出 events/ 至中立位置，或作 `Admission.Offering` 上游端口）；中文统一语言定名**供给物**。模块变薄：纯读取投影契约，零写入；Events/Courses 各实现 adapter。消费面不变：Admission 校验、小程序分享深链（target_kind/target_id）、PendingApprovals 标题、通知 target_title、GraphQL offeringReadiness、公开浏览族。
6. **D6：Payments 为 supporting domain，Order 锚 enrollment_id 不变。** 报名是唯一收费场景（赞助 v1 不收款），**放弃 `(subject_kind, subject_id)` 泛化**（无需求抽象）；Admission 独立后 order.ex 的 event/course 双分叉 JOIN 收敛为单 JOIN。资金对账（PaymentReconciliationWorker / ReplaySettlement）留 Payments 域内；Reconciliation Finding 底座与 /admin 对账页保持「底座共享 + 扫描器归各域」结构不动。**（实施期补记，2026-08-29 Fable 5 评审 M2：PR⑤ 漏收一处逆向写点——Enrollment 直写 `payments_orders` 作废 pending 单的裸 SQL,已收编为 Payments 端口 `Order.void_pending_for_enrollment/2`,Admission 侧三处调用点改走端口,语义逐行等价。）**
7. **D7：教研英文命名 = Curriculum。** Research 太宽泛，Teaching Research 为中式英语；学科通用名 instructional design，命名取产出物本质（Curriculum = 课程编制）。`ResearchOutput → Curriculum 家族`、`ResearchInstantiator → CurriculumInstantiator`、`research_enabled → curriculum_enabled` 等改名随迁移序列进行；中文文档继续称「教研」。
8. **D8：迁移策略——模型先行、五步 PR 序列**（数据库可重置，无绞杀/兼容层）：
   - **PR① Admission 抽出**：Enrollment/InviteBatch 迁入 `admission/`；Offering 读契约改上游端口（移出 events/）；信号名 `enrollment.*` 不变（订阅方零改动）。
   - **PR② Courses 独立**：Course 迁出 events/ 建 `courses/`；Event 留 `events/`（Venue/SpeakerInvitation 随迁不动）；`course.*` 信号名不变。
   - **PR③ Curriculum 独立 + 改名**：ResearchOutput 家族迁 `curriculum/` 并改名；content 读契约归位；`research_*` 命名退役。
   - **PR④ Sponsorship 独立**：Sponsorship 家族迁 `sponsorship/` + `Cgc2046.Sponsorship` domain；Event 侧保持软引用。**（更正补记，2026-08-28 实施期：本步在原序列漏排——D4 已决策 Sponsorship 独立，D8 却未列入迁移序列；随实施计划 KTD8 更正单列。）**
   - **PR⑤ Payments 收敛 + 名额账本 + domain 收尾**：Order 引用收敛单 JOIN；名额账本表 + capacity 投影同步 + confirmed_count 展示投影化；Workflows / Learning / Reconciliation 各建 domain 归位，`Cgc2046.Api` 退役删除。
   - 每步独立 PR、CI 全绿才走下一步；CONTEXT.md / 领域模型定稿随 PR 同步。
   - **实施状态（2026-08-28）**：五步全部合入，本 ADR 落地完成。

### 拒绝的替代

- **Enrollment 双表复制**（EventEnrollment/CourseEnrollment）：一词两义违背统一语言；名额 CAS、审批超时、缴费状态机等纪律双份维护，缴费闭环回归面翻倍。
- **`(subject_kind, subject_id)` 泛化支付**：Order 唯一收费场景是报名，泛化是无需求抽象（YAGNI）。
- **浅拆（仅 course.ex 移目录）**：不解耦——Enrollment/InviteBatch 仍双 belongs_to，Offering 仍跨 kind；目录搬家不等于边界。
- **content 归 Learning**：content 是教研**产出物**（写侧在 Tutor/教研 workflow），Learning 是读侧消费方；归 Learning 会把写作权错配给消费方。
- **绞杀式迁移 / 数据迁移**：数据库可重置（用户量 = product owner 一人），模型先行整体切换即可。

## 后果（Consequences）

- **正面**：Events 与 Courses 获得独立演进面（persona 与变更频率分叉被边界承认）；报名/缴费不变量收敛在 Admission/Payments 单 context 内，事务纪律不再跨域；跨 context 写点清零（D2）；命名通过统一语言检验（供给物/教研=Curriculum）。
- **代价/风险**：
  - GraphQL schema 类型归属调整 → `web/` 前端与小程序查询跟着改（每步 PR 内消化）。
  - D2 引入 capacity 投影同步窗口：极端场景（调小容量瞬间报名）由账本 CAS 拒单 + 对账规则兜底，不构成超卖。
  - 「我的报名」/admin 聚合/PendingApprovals 等 union 读面改经 Offering 端口，需防 N+1 退化（沿用 `fetch_titles_by_ids` 批量形状）。
  - 信号名（`enrollment.*`/`course.*`/`event.*`）是跨 context 发布语言，改名成本极高——本次**不动信号名**。
- **文档落点**：本 ADR + `领域模型定稿.md` §5.4 + CONTEXT.md 术语同步（Admission/Curriculum/供给物词条）先行；代码随五步序列跟进（2026-08-28 全部完成，含名额账本词条与 KTD7 锁序成文）。
