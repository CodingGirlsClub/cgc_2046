---
title: Slice E 整合计划 — ideation 方向融入（Idea 2-7 修订版）
type: plan
date: 2026-08-13
topic: course-event-slice-e
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: issue 118 规划讨论稿修订
execution: code
---

# Slice E 整合计划：ideation 方向融入（Idea 2-7 修订版）

> 修订自 issue #118。差异：Idea 1 已合并（PR #119），Phase 0 完成；本计划把 Idea 2-7 逐项定稿为可执行的 phase 规格。**状态：2026-08-13 用户签核「全部同意」——D1-D8 已批准**（签核包 `docs/signoff/2026-08-13-001-slice-e-ideation-integration.md`）；issue 已登记（#122-#125 新增，#46/#47/#48/#50 修订）。

## Goal Capsule

- **Objective:** 把 `docs/ideation/2026-08-12-course-event-slice-e-ideation.html` 的 Idea 2-7 讨论定稿并融入 slice E 骨架（E-1..E-6 + 新增 E-7..E-10），产出依赖拓扑、推荐执行顺序、逐 phase 交付物与验收、需用户拍板的 8 项决策。
- **Product authority:** 用户；决策 D1-D8 已于 2026-08-13 全部批准（推荐方案）。
- **Open blockers:** 无研究阻塞；唯一前置依赖 #39 已 CLOSED（C-6 完成）。

---

## 一、现状证据（2026-08-13, develop 7489d42 — PR #121/#126 已合入）

| 声明 | 证据 |
|---|---|
| Idea 1 已落地 | PR #119 合并：ADR-0005（`docs/adr/0005-workflow-run-worthiness.md`）；`enrollment.ex:23-25` submitted/completed 信号常量，`:135-160` after_transaction 发布；`approval_reminder_worker.ex:7-11` run-less 报名扫描；报名 doc 头部「部分退稿（2026-08-12）」；GraphQL `create_enrollment` mutation（`enrollment.ex:239-243`） |
| signal_idempotency 表 | PR #121（OPEN）已提供 migration + `SignalIdempotency.claim/3`（唯一索引 `(signal_type, idempotency_key)` + insert_all on_conflict）；E-9/E-2/E-3 去重基座 |
| Event/Course 生命周期 | `event.ex:30` 四态；launch 自 C 阶段、close/cancel 自 E-9（PR #126 合入）；`event.ended`/`course.ended` 已生产（事务内 outbox） |
| WorkflowRun 已含 expired 终态 | `workflow_run.ex:57` `@status_values [... :cancelled, :expired]`（slice C #35）——赞助 F7 无需新增状态机 |
| 报名窗 SQL 守卫已存在 | `enrollment.ex:392-395` `WHERE status='open' AND (registration_deadline IS NULL OR > NOW())`；pending 过期由 `expire` action 承担（`:342-346`） |
| 通知基础设施完整 | `NotificationSubscriber` patterns=`enrollment.approved/rejected`（`notification_subscriber.ex:13`）；`NotificationService`/`NotificationWorker`/`NotificationConsent` 齐备 |
| ResearchInstantiator 静默跳过 | `research_instantiator.ex:168-172` 无 published 定义 → warning skip「供对账」 |
| 审批聚合已建、web 零消费 | `pending_approvals.ex:50-58` Enrollment+JoinRequest；GraphQL `my_pending_approvals`（`cgc_2046_web/graphql_schema.ex:116-120`） |
| 赞助/邀请零实现 | 无 Sponsorship/SpeakerInvitation 资源文件；总纲:90 `sponsorship_enabled`/`materials_review_required` 代码缺失 |
| web 现状 | `web/app/w/[slug]` 仅 workspace 页 + 占位卡；无 `/events`、`/courses` 任何页面；`web/app/admin/*` 已建成（2026-08-10 admin plan 已实施）；GraphQL 无 createEvent/launchEvent/closeEvent mutation（event.ex GraphQL 仅 queries）——**活动创建/发布/结束无产品面入口（用户 2026-08-13 发现）** |
| slice E 骨架 | #46-51 全 OPEN（label ready-for-agent）；#39 CLOSED COMPLETED；新增 #122（E-7）/ #123（E-8）/ #124（E-9，PR #126 已合入）/ #125（E-10）/ #127（E-11 活动管理面，用户拍板新增） |
| 总纲 v1 待办 | 总纲:218-223：报名 #5-②（实体自序贯后消解，见 Idea 5 注）、邀请 #2（→ E-4）、赞助 #5（→ E-3 + E-9）、教研 #8（非 slice E，出界） |

## 二、Idea 2-7 定稿规格

### Idea 5 · 生命周期级联 → 新增 E-9

**设计**
- `close` 动作（open→closed）：手动 + `registration_deadline` 到点自动（Oban cron，复用 `ApprovalExpiryWorker` 模式）；`cancel` 动作（→cancelled）。
- 两动作 after_transaction 发 `event.ended`/`course.ended`（publish 失败入队 SignalPublishWorker 重试，至少一次投递；消费方经 signal_idempotency claim 去重，claim 后置于副作用成功后写入）。closed/cancelled 即结束语义——代码无 `end_at`，不引入新字段（决策 D4）。**终态不可逆（v1）**：closed/cancelled 无恢复 action，误操作恢复路径 = 新建活动（避免生命周期 epoch 版本化的复杂度；codex 评审 BLOCKING 6 定稿）。

**验收**：close/cancel 动作测试；ended 信号幂等投递测试；教研 run 回收测试；deadline 到点自动 close 测试。

### Idea 3 · 公开发现面 → E-5 #50 增强（经 E-11 可见性轴修订）

**可见性轴（2026-08-13 用户拍板）**：新增 Event/Course `visibility: public | workspace` 字段——「私享会」= `visibility=workspace + enrollment_policy=invite_only`（全员可见、凭码报名，用户拍板 A：**不引入第四轴成员级可见性**）。默认 `public`；**可随时双向切换（含 open 后）**——公开页查询读时评估，切换零数据迁移；已报名非成员在切到 workspace 后失去详情访问（Enrollment/学习 run 不受影响）。落在 E-11 #127 交付。

**设计**
1. **读策略条件**（D2 修订）：`status=open AND visibility=public` ⇒ 匿名可读；其余 status/visibility 一律成员可读；写入不动。公开字段白名单 = 决策 D2。
2. **公开宿主页**：`/events/[slug]`、`/courses/[slug]` + 公开发现页列表（**只列 open + public**），消费 #40 已建已测查询；报名轻量表单消费 `create_enrollment` mutation（已暴露）；赞助/邀请入口挂宿主页（随 E-3/E-4 补上）。`workspace` 活动报名入口在 workspace 内详情页（E-11）。
3. **GO/NO-GO readiness**（决策 D3）：launch 时校验清单，v1 警告放行 + readiness 查询暴露后台。清单 v1：① `registration_deadline` 已设（null 合法=无截止，仅提示）；② `sponsorship_enabled=true` 时 tiers 已配置；③ published research 定义存在（无则 warning——现状 `research_instantiator.ex:168` 静默跳过）。

**验收**：匿名 GET open+public event 200 且字段在白名单内；workspace 活动与非 open 匿名拒绝；表单提交 → Enrollment 落库；GO/NO-GO 缺项产生 warning + readiness 可查。

### Idea 4 · 审批控制台 → 新增 E-8

**设计**
- 泛化 PendingApprovals 为 kind-agnostic；后台审批页消费 `my_pending_approvals` + 按 kind dispatch approve/decline（Enrollment → 已有 `confirm_enrollment`/`reject_enrollment` mutation；JoinRequest → 既有；Sponsorship → `sponsorship.approved`/`.rejected`，赞助 doc §2.2 A1）。
- 行形状（决策 D7）：`{kind, id, requester 摘要, context 摘要, approval_deadline}`；UI 按原型验证结论 #4（琥珀/青色脉冲 + 48h 倒计时 + expired 重提入口）。
- **不含 WorkflowRun-waiting**：StepAuthorization 是 run 内授权，语义不同，纳入会双重授权（决策 D7）。

**验收**：pending 列表渲染 + 倒计时；通过 → Enrollment confirmed + `enrollment.approved`/`completed` 信号；赞助 kind 随 E-3 接入同一表面。

### Idea 6 · 赞助履约账本 → E-3 #48 增强

**设计**
- Sponsorship/SponsorshipTier 资源（总纲:93 字段：level/tier_id/status pending|active|rejected|expired|ended）；引擎化 + 审批两段式（赞助 doc §2.1，POC §3.3/§3.4 PASS）；F7 语义（expired 终态 + 48h 提醒 + 可重提；WorkflowRun.expired 已备）。
- **履约账本**（决策 D5）：`SponsorshipDelivery`（sponsorship_id、benefit、due_date、fulfilled_at、proof_note；独占位标记）；激活 A3 时从 `tier.benefits` 物化交付行；后台逐项核销 proof-of-performance；独占权益位条件 UPDATE 防双重预定（复用 enrollment 名额扣减模式）。makegood 不做（依赖二期续期闭环），欠交付以未核销行可见。需修订赞助设计 doc（v1.3）。
- Event 级 ended 订阅 E-9 的 `event.ended`（赞助 doc #5 待 v1 项由此落地）。

**验收**：sponsorship_flow_test（两级）；账本物化/核销/独占位测试；event.ended → Event 级 Sponsorship 自动 ended 测试。

### Idea 2 · 学习 workflow 设计 → 新增 E-7

**设计（先行，零代码依赖）**
- 协议而非 DAG：`enrollment.completed` 幂等触发（键 `"enrollment.completed:" + enrollment_id`，报名 doc §4.2）+ 经已门控的 `save_step_output` 逐 manual step 写 facts + run.facts 授权账本；平台侧不编排执行（BYO）。
- care-pathway 语义补三决策（决策 D6）：
  1. **variance**：跳过/偏离步骤须写原因 → `save_step_output` 载荷加可选 `reason` 字段，随 facts 落账本；
  2. **completion/discharge**：定义末步完成 ⇒ run succeeded，产出即工件（同教研收尾段模式）；
  3. **停滞升级**：平台不编排（BYO）→ 停滞检测交给对账扫描（E-10 停滞规则）+ 48h 提醒模式复用（N 天无 step 输出 → 报告 + 提醒，N 默认 7）。

**实现（依赖 E-2 订阅方）**：`LearningInstantiator`（`research_instantiator.ex` 同款 find_or_create 蓝图）。

**验收**：设计文档 + 三决策定稿；实现后：`enrollment.completed` → learning run 幂等实例化；`save_step_output` 写 facts；停滞规则入对账。

### Idea 7 · 对账扫描 → 新增 E-10

**设计**：平台级 Oban job（复用 expiry worker 跨租户扫描模式）+ 孤儿报告 + 后台对账页（落 `web/app/admin` 已建 audit 面）。
**v1 规则**（决策 D8）：① confirmed enrollment 无 learning run（E-7 后启用）；② pending 无 `approval_deadline`；③ sponsorship active 但无 `sponsorship.active` signal_log；④ open event 无 published research 定义。

**验收**：注入孤儿数据 → 报告命中；无孤儿 → 空报告；报告后台可读。

### E-2 #47 修订 · 异步 Signal 订阅方

生产者已建（PR #119）。剩余：① NotificationSubscriber patterns 扩展 `enrollment.submitted/completed`（通知学员/志愿者）；② 学习触发（E-7）；③ 赞助权益更新（E-3 后）；④ 去重依赖 signal_idempotency 表（PR #121）。

### E-1 #46 修订 · 报名实体自序贯

body 移除 ash_jido/人工步骤表述（已按 ADR-0005 实体自序贯）；验收改为：`create_enrollment` 三策略主链路 + 重复报名拒（既有 identity `unique_event_user`/`unique_course_user`）+ web 表单 E2E（随 E-5）。

## 三、依赖拓扑与推荐执行顺序（E-11 前置修订）

```
[✓ Phase 0] 判据 + 报名最小接线（PR #119 已合并）
      │
      ▼
[✓ Phase 1] E-9 生命周期级联（#124，PR #126 已合入）
      │
      ▼
[Phase 2] E-11 workspace 活动管理面（#127）  ← visibility 字段 + 读策略条件（D2 落点）
      │                                        + GraphQL mutations + 管理/详情页；成员见全量
      ▼
[Phase 3] E-5 公开发现面（#50，Idea 3）       ← 只消费 open + public
      │
      ▼
[Phase 4] E-8 审批控制台（#123，Idea 4）      ← 报名审批 E2E；赞助审批前置
      │
      ▼
[Phase 5] 三线落地：E-3 赞助（#48，+Idea 6 账本）、E-4 邀请（#49）、E-2 订阅方收尾（#47）
      │
      ▼
[Phase 6] E-7 学习设计（#122，Idea 2）        ← 设计文档已交（可并行）；实现依赖 E-2
      │
      ▼
[Phase 7] E-10 对账扫描（#125，Idea 7）       ← 规则随 workflow 累积，最后落地
      │
      ▼
[Phase 8] E-6 #51 端到端验证（按 AGENTS.md 确定性分层）
```

- **无依赖（可立即启动）**：Phase 2（E-11，后端动作已备）、E-7 设计文档（已交付 `docs/01-定稿设计/学习workflow详细设计.md`）。
- **并行窗口**：Phase 2 ∥ E-4 邀请（核心独立，token 着陆页依赖 Phase 3）。
- **强依赖**：E-5 ← E-11（visibility 字段 + 读策略条件）；E-3 ← Phase 1（ended）+ Phase 4（审批面）+ D5（账本）；E-2 订阅方 ← Phase 1（幂等表）；E-10 ← 各 workflow 规则。

## 四、决策清单（9 项 — D1-D8 用户签核「全部同意」；D9 二次拍板）

| # | 决策 | 结论 | 性质 |
|---|---|---|---|
| D1 | 新增 E-7/E-8/E-9/E-10 issue + 修订 #46/#47/#48/#50 body | ✅ 已执行（#122-#125，#46/#47/#48/#50） | 工作登记 |
| D2 | 公开字段白名单（读策略翻转的安全语义） | ✅ 批准 → **D9 修订为条件式**：`open + visibility=public` 才匿名可读；白名单字段不变（capacity/confirmed_count 不公开） | 安全变更 |
| D3 | GO/NO-GO 语义 | ✅ 批准：v1 警告放行 + readiness 查询 | 产品语义 |
| D4 | 级联触发时点 | ✅ 批准：close 手动 + registration_deadline 到点自动；closed/cancelled 即 ended | 产品语义 |
| D5 | 履约账本引入设计外实体 | ✅ 批准：SponsorshipDelivery 最小账本；makegood 二期；修订赞助设计 v1.3 | 范围变更 |
| D6 | 学习三语义（variance/completion/停滞） | ✅ 批准：reason 字段 / 末步即 discharge / 对账 + 提醒（N=7） | 设计定稿 |
| D7 | 审批控制台形状 | ✅ 批准：kind-agnostic；v1 不含 WorkflowRun-waiting | 设计定稿 |
| D8 | 对账规则与消费纪律 | ✅ 批准：四条规则 + 规则⑤（B3 兜底）；报告落 /admin 对账页 | 设计定稿 |
| D9 | 可见性轴 + E-11 | ✅ 拍板（2026-08-13）：新增 `visibility: public\|workspace`；无第四轴（拍板 A，「私享会」= workspace+invite_only）；成员见 workspace 全量活动；默认 public；**visibility 可随时双向切换（含 open 后，用户拍板）**；E-11 先行 | 产品语义 + 工作登记 |



## 五、范围边界

- **不做**：收款/支付（payment_pending→paid，二期）；候补；Event/Course 收敛单一 Offering（ideation 被裁 #21，收益待第三 workflow 落地后单独 brainstorm）；平台托管 Learner 档；邀请批量/候选池（二期）；makegood 闭环（依赖续期）；教研 #8 答疑交互（非 slice E）；**成员级活动可见性（第四轴——拍板 A，「私享会」= workspace + invite_only 已覆盖，v1 不做）**。
- **不改既有拍板**：#3（审批入口=网站后台审批页）、F7（7 天过期+48h 提醒+可重提）、D-A6（同步/异步 8:2）、D-A4（报名≠成员）、KD1-5（run-worthiness plan）、ADR-0005。
- **依赖门禁**：新依赖须 AGPL-3.0-compatible（`mix cgc2046.check_licenses` + `pnpm check:licenses`）。

## 六、Sources / Research

- `docs/ideation/2026-08-12-course-event-slice-e-ideation.html` — Idea 1-7 + verifier 裁决。
- `issue://118,46,47,48,49,50,51,39,122,123,124,125`、`pr://121` — 整合讨论稿、slice E 骨架、C-6 状态、signal_idempotency PR。
- `docs/adr/0005-workflow-run-worthiness.md`、`docs/plans/2026-08-12-001-feat-workflow-run-worthiness-plan.md` — Idea 1 落地。
- `docs/00-CGC平台设计总纲.md`（:90,:105,:171,:177,:191,:218-223）、`docs/01-定稿设计/报名workflow详细设计.md`（§3.4/§3.5/§4.2/§4.3）、`docs/01-定稿设计/赞助workflow详细设计.md`（§1.2/§2.1/§2.2/§3.3/§3.4/§5.1）、`docs/01-定稿设计/邀请workflow详细设计.md`（§7 #2）、`docs/01-定稿设计/用户旅程与Web功能清单.md`（J-Visitor:89-95, J-Sponsor:171-177, 页面清单:239-252）。
- 代码：`backend/lib/cgc_2046/events/enrollment.ex`（信号/身份/expire/SQL 守卫）、`event.ex`/`course.ex`（死枚举、launch）、`workflows/workflow_run.ex:57`（expired 终态）、`research_instantiator.ex:117-172`（静默跳过供对账）、`notification_subscriber.ex:13`、`pending_approvals.ex:50-58`、`cgc_2046_web/graphql_schema.ex:116-120`；`web/app/*`（admin 已建、无 events/courses 页）。
- Roster：`/tmp/sop-roster-e.json`（probe 2026-08-13）。
