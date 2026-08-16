# CGC 平台架构图审查发现（REVIEW-FINDINGS）

> 编写：架构可视化工程师（worker_8984c7a9）
> 来源：绘制 docs/diagrams/ 下 16 张 L0–L4 图的过程中，对照 `docs/00-CGC平台设计总纲.md`、
> `docs/01-定稿设计/*.md`、`docs/04-引擎验证/poc-验证报告.md` 交叉核对发现的设计问题、矛盾与遗漏。
> 每条均已同步标注到对应 `.puml` 图的 note 中。
>
> 严重度约定：🔴 阻断/必须拍板 · 🟡 建议 v1 内补 · 🟢 已确认/仅记录

---

## F1 ✅ 已闭环（2026-08-16 漂移对账：决策升级为「永久绕开」）

- **图**：`signal-join-strategies.puml`、`workflow-enrollment.puml`、`workflow-sponsorship.puml`
- **问题描述**：同一 workflow 内用 join 等待两个以上异步信号，在 Agent 策略（auto）下会死锁——
  feed1 后 join 进入 ran_nodes（视为"已执行"）；feed2 时 join 已满足却被 ran_nodes 过滤，
  create/notify 永不执行（POC §3.3 双向证明）。v1 用"第一段落 DB + 第二段信号恢复"的两段式绕行，
  但这是**架构层规避**，不是引擎缺陷修复。
- **涉及文档**：poc-验证报告.md §3.3；报名workflow详细设计.md §6；赞助workflow详细设计.md §6
- **建议方向**：v1 主路径固定走 Workflow 层（runic 直接驱动，join 模式可用，POC §3.2 PASS）；
  适配层必须内置"多信号分批 feed"集成测试防回归。若二期仍需 Agent 策略，需向 jido 上游报 ran_nodes 缺陷或自定义 join。

## F2 ✅ 已闭环（2026-08-16 漂移对账关闭；落地形态与原建议不同）

- **图**：`hibernate-thaw.puml`、`workflow-run-state.puml`（两图已按码现状更新）
- **原问题**：POC-2 G1 覆盖了"waiting 挂起 → 信号到达 thaw → 恢复执行"，但
  "挂起期间 deadline 到点自动唤醒并 cancel"未验证。
- **实际落地**：`ApprovalExpiryWorker`（Oban cron */5min）扫 `WorkflowRun status=waiting` +
  `ApprovalDeadline.overdue?`（deadline = updated_at + definition.approval_timeout，nil = 永不）
  → `:expire`（pending/waiting → **expired**，非原建议的 cancelled；含 checkpoint 清理）。
  集成测试即"POC-2 G1 补测"（approval_expiry_worker_test.exs）。
- **涉及文档**：DRIFT-REPORT §5.4 L3-3.5 / §5.3 L2-4；approval_expiry_worker.ex:63-99
- **遗留**：Enrollment/Sponsorship 实体的 pending→expired 扫描同 worker 承担（六资源规格），
  本条按 run 级唤醒语义关闭。

## F3 🟢 幂等键承载：勿用 action 进程 ETS

- **图**：`key-routing-isolation.puml`、`workflow-enrollment.puml`
- **问题描述**：幂等三层（request_id + 业务唯一索引 + signal idempotency_key）的**承载位置**是
  Postgres 唯一约束 / Redis；**不能**放在 action 进程的 ETS 表里——进程重启即丢、且无法跨实例共享
  （POC-2 已实证 ETS 陷阱）。
- **涉及文档**：报名workflow详细设计.md §6.4；poc-验证报告.md
- **建议方向**：已按设计落图，无分歧；实现时把"幂等键存储"列为显式依赖（Postgres/Redis），
  并在代码评审清单中禁止 ETS 承载。

## F4 ✅ 已闭环（2026-08-17 缴费闭环落地；落点与原设想不同）

- **图**：`entity-state-machines.puml`、`workflow-enrollment.puml`、`domain-model-er.puml`（已同步）
- **原问题**：Sponsorship v1 不收款、状态机未预留收款态；建议二期在赞助侧插 payment_pending→paid。
- **实际落地**（plan 024 缴费闭环，#181/#184/#187）：支付落在 **Enrollment 侧**——Enrollment 6 态含
  `payment_pending`（有价档报名 → Order → 渠道支付 → webhook 落账 → settlement worker 驱动 confirmed；
  `waive_payment` 免缴分支）；独立 payments 域（Order 7 态 + WebhookEvent + Provider wechat/alipay/fake 三
  adapter + 5 个 worker）。**Sponsorship 仍 v1 不收款**——若二期赞助缴费，复用 payments 域与 Enrollment
  同构模式，而非在赞助状态机内插桩。

## F5 🟢 凭据模型差异：invite_only 共享批次码 vs 逐人 token

- **图**：`workflow-invitation.puml`、`workflow-enrollment.puml`
- **问题描述**：报名 invite_only = 共享批次码 + quota（InviteBatch 一对多、可多人兑换）；
  演讲邀请 = 逐人 token（一对一、一次性、accept/decline 后失效）。两者安全模型完全不同，
  不能共用一个凭据校验实现。
- **涉及文档**：邀请workflow详细设计.md §4；报名workflow详细设计.md §4
- **建议方向**：已确认设计如此；实现时 InviteBatch 校验（配额 + 有效期）与 SpeakerInvitation 校验
  （token_hash 一次性）分属两个 Action，勿合并。

## F6 🟢 邀请接受/拒绝是互斥双分支，非拆段（审批两段式）

- **图**：`workflow-invitation.puml`
- **问题描述**：接受/拒绝是同一决策点的互斥双分支，Workflow 层单 run 可表达（POC §3.2 PASS）；
  不需要为邀请拆两段（审批两段式仅适用于顺序人工信号场景）。v1 也不拆独立分享 workflow（拍板 #4），材料产出内嵌 M1。
- **涉及文档**：邀请workflow详细设计.md §4；开放问题决策清单.md 拍板 #4
- **建议方向**：已确认；保留 speaker.accepted 触发扩展点即可。

## F7 ✅ 已闭环（2026-08-16 漂移对账：approval_timeout 已落地）

- **图**：`workflow-run-state.puml`、`entity-state-machines.puml`（已按码现状更新）
- **问题描述**：审批（报名 pending / 赞助 pending）的**超时策略未定死**：设计默认"无超时自动拒绝
  （人为决策）"，"可选 N 天自动过期"标注为可选。这影响 hibernate 挂起时长与运维 SLA。
- **涉及文档**：报名workflow详细设计.md §3.4；赞助workflow详细设计.md §3.4
- **实际落地**：`WorkflowDefinition.approval_timeout` 参数已实现（workflow_definition.ex:107-112）；
  ApprovalDeadline 唯一真源 + ApprovalExpiryWorker（*/5min）+ 实体/run 双侧 expired 态 +
  ApprovalReminderWorker 48h 提醒（workers/approval_reminder_worker.ex）。nil = 永不超时的
  语义与"人为决策"场景并存。
- **处置**：闭环；DRIFT-REPORT §5.3 L2-4 / §5.4。

## F8 ⚪ 更正（2026-08-16 漂移对账：描述了不存在的机制）

- **图**：`confirm-flow.puml`（已按码现状更正）
- **原记录**：高风险工具确认流的 auto_approve 模式是 10s 倒计时自动决策，存在误放行风险。
- **对账结论**：**auto_approve 在码中从未实现**（全库 grep 零命中，既未实现也未配置）——
  本条系把设计讨论当作已实现风险记录。实际确认流只有 two-tool 模式
  （create_invitation → confirm_operation / cancel_operation），高风险面即一个工具。
- **处置**：风险不存在，关闭；若未来引入 auto_approve，按原建议（默认关/白名单）重新评估。
- **证据**：DRIFT-REPORT §5.4 confirm-flow 行；grep backend `auto_approve|10s|countdown` 零命中。

## F9 🟢 形态 X：网站无对话页/执行页，靠 OpenClacky + MCP

- **图**：`system-context.puml`、`architecture-overview.puml`、`user-journeys.puml`
- **问题描述**：聊天与 Agent 执行全在用户自己的 OpenClacky，经 MCP 调用网站；网站只做业务中枢
  与产出/审计展示。该形态对"网站内嵌对话/引导"类需求是明确否决项。
- **涉及文档**：总纲 D4；用户旅程与Web功能清单.md
- **建议方向**：已确认；前端迭代时勿引入对话页，Web 功能清单需与该形态保持一致。

## F10 🟢 Learner 双角色关系互不替代

- **图**：`domain-model-class.puml`、`domain-model-er.puml`、`user-journeys.puml`
- **问题描述**：Learner 既可以是 Workspace 成员（长期运营角色，WorkspaceMembership+Role），
  也可以是 Event/Course 参与者（事件级，Enrollment）。判断"谁能执行 Step"看成员角色；
  判断"谁报名了活动"看 Enrollment。
- **涉及文档**：领域模型定稿.md §2.1/§4.3
- **建议方向**：已确认；实现时两条关系链不合并，权限判定按场景取不同关系。

## F11 🟡 赞助 A3 无并发扣减，tier.limit 二期将引入并发问题

- **图**：`workflow-sponsorship.puml`、`domain-model-er.puml`
- **问题描述**：报名 A3 = pending→confirmed 扣名额（有并发约束，(event_id,user_id) 唯一索引兜底）；
  赞助 A3 = pending→active 生效权益，v1 不限额、无并发扣减。但 tier.limit 标注二期——引入限额后
  会面临与报名相同的并发扣减问题。
- **涉及文档**：赞助workflow详细设计.md §5/§6；领域模型定稿.md §5.2
- **建议方向**：二期实现 tier.limit 时复用报名 A3 的原子扣减模式（唯一索引 + 条件更新），
  现在先在设计中预留"额度扣减"动作接口。

## F12 ✅ 已闭环（与 F1 同源：Workflow 层顺序 join + 多信号回归测试已内置）

- **图**：`workflow-research.puml`、`template-parameterization.puml`
- **问题描述**：教研流程含多个顺序人工信号（大纲确认、物料、答疑等）。Workflow 层顺序 join 已证
  PASS（POC §3.2）；Agent 层多信号需拆段（Agent 策略层缺陷规避）。v1 主路径 = Workflow 层。
- **涉及文档**：教研workflow详细设计.md §6；poc-验证报告.md §3.2
- **建议方向**：与 F1 同源；实现时教研 workflow 的适配层同样内置多信号分批 feed 测试。

---

## 汇总统计（2026-08-17 增量对账后更新）

- ✅ 已闭环：5（F1 join 永久绕开+回归测试、F2 deadline 唤醒、F4 缴费闭环落地（Enrollment 侧）、F7 approval_timeout 落地、F12 与 F1 同源）
- ⚪ 更正关闭：1（F8 auto_approve 从未实现）
- 🟡 仍开放：1（F11 tier.limit 二期并发扣减）
- 🟢 已确认/仅记录：5（F3、F5、F6、F9、F10）

**漂移对账**：完整对照见 [DRIFT-REPORT.md](./DRIFT-REPORT.md)；2026-08-16 全量对账（R1–R10 裁决执行）+
2026-08-17 增量（payments #181/#184/#187、course-issue #183/#186 合入后同步）。剩余动作：F11 随二期实现。
