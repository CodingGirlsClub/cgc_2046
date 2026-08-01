# CGC 平台架构图审查发现（REVIEW-FINDINGS）

> 编写：架构可视化工程师（worker_8984c7a9）
> 来源：绘制 docs/diagrams/ 下 16 张 L0–L4 图的过程中，对照 `docs/00-CGC平台设计总纲.md`、
> `docs/01-定稿设计/*.md`、`docs/04-引擎验证/poc-验证报告.md` 交叉核对发现的设计问题、矛盾与遗漏。
> 每条均已同步标注到对应 `.puml` 图的 note 中。
>
> 严重度约定：🔴 阻断/必须拍板 · 🟡 建议 v1 内补 · 🟢 已确认/仅记录

---

## F1 🔴 Agent 策略层 join 双信号死锁 —— 审批两段式规避（v1 主路径 Workflow 层原生）

- **图**：`signal-join-strategies.puml`、`workflow-enrollment.puml`、`workflow-sponsorship.puml`
- **问题描述**：同一 workflow 内用 join 等待两个以上异步信号，在 Agent 策略（auto）下会死锁——
  feed1 后 join 进入 ran_nodes（视为"已执行"）；feed2 时 join 已满足却被 ran_nodes 过滤，
  create/notify 永不执行（POC §3.3 双向证明）。v1 用"第一段落 DB + 第二段信号恢复"的两段式绕行，
  但这是**架构层规避**，不是引擎缺陷修复。
- **涉及文档**：poc-验证报告.md §3.3；报名workflow详细设计.md §6；赞助workflow详细设计.md §6
- **建议方向**：v1 主路径固定走 Workflow 层（runic 直接驱动，join 模式可用，POC §3.2 PASS）；
  适配层必须内置"多信号分批 feed"集成测试防回归。若二期仍需 Agent 策略，需向 jido 上游报 ran_nodes 缺陷或自定义 join。

## F2 🟡 hibernate/thaw 未覆盖 deadline 到点唤醒 → cancel 路径

- **图**：`hibernate-thaw.puml`、`workflow-run-state.puml`
- **问题描述**：POC-2 G1 A1–A5 全 PASS 覆盖了"waiting 挂起 → 信号到达 thaw → 恢复执行"，但
  **"挂起期间 deadline 到点自动唤醒并 cancel"未验证**。报名截止/审批超时都依赖该路径。
- **涉及文档**：poc-验证报告.md G1；报名workflow详细设计.md §3.4
- **建议方向**：v1 补集成测试：恢复时检查 deadline → Emit cancel（或 Schedule Directive），
  断言 waiting 超时后 run 转 cancelled、截止后 submitted 信号不再放行。

## F3 🟢 幂等键承载：勿用 action 进程 ETS

- **图**：`key-routing-isolation.puml`、`workflow-enrollment.puml`
- **问题描述**：幂等三层（request_id + 业务唯一索引 + signal idempotency_key）的**承载位置**是
  Postgres 唯一约束 / Redis；**不能**放在 action 进程的 ETS 表里——进程重启即丢、且无法跨实例共享
  （POC-2 已实证 ETS 陷阱）。
- **涉及文档**：报名workflow详细设计.md §6.4；poc-验证报告.md
- **建议方向**：已按设计落图，无分歧；实现时把"幂等键存储"列为显式依赖（Postgres/Redis），
  并在代码评审清单中禁止 ETS 承载。

## F4 🟢 赞助 v1 不收款，状态机需二期插 payment_pending → paid

- **图**：`entity-state-machines.puml`、`workflow-sponsorship.puml`、`domain-model-er.puml`
- **问题描述**：v1 只做意向 + 审批 + 权益生效，amount 仅登记、不收款；但 Sponsorship 状态机
  当前是 pending→active→ended，**没有预留收款态**。二期加支付时若直接改状态机会影响已运行 run。
- **涉及文档**：赞助workflow详细设计.md §5.2/§6；开放问题决策清单.md
- **建议方向**：v1 起就在状态机模型里**预先声明**二期插桩点（pending→payment_pending→paid→active，
  插在 active 之前），定义快照机制保证已启动 run 不受影响；tier.limit 同理标注二期。

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

## F7 🟡 审批超时语义未拍板：默认无超时自动拒绝

- **图**：`workflow-run-state.puml`、`entity-state-machines.puml`
- **问题描述**：审批（报名 pending / 赞助 pending）的**超时策略未定死**：设计默认"无超时自动拒绝
  （人为决策）"，"可选 N 天自动过期"标注为可选。这影响 hibernate 挂起时长与运维 SLA。
- **涉及文档**：报名workflow详细设计.md §3.4；赞助workflow详细设计.md §3.4
- **建议方向**：v1 拍板默认值（建议 7 天自动过期 + 过期前提醒），并在 WorkflowDefinition 上暴露
  approval_timeout 参数；若采用"无超时"，需保证 run 长期 waiting 不影响系统资源（依赖 F2 的 hibernate）。

## F8 🟡 auto_approve 模式 10s 倒计时自动决策存在风险

- **图**：`confirm-flow.puml`
- **问题描述**：高风险工具（assign_role / create_invitation / 审批类）确认流的 auto_approve 模式
  是 10s 倒计时自动决策——倒计时内无人工介入即自动通过，存在误放行风险。
- **涉及文档**：总纲 D8 确认流；用户旅程与Web功能清单.md
- **建议方向**：v1 默认关或仅限白名单工具；二期可加冷却期（同工具短时间重复调用不再 auto_approve）。

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

## F12 🟢 教研多人工信号顺序等待：Workflow 层可、Agent 层需拆段

- **图**：`workflow-research.puml`、`template-parameterization.puml`
- **问题描述**：教研流程含多个顺序人工信号（大纲确认、物料、答疑等）。Workflow 层顺序 join 已证
  PASS（POC §3.2）；Agent 层多信号需拆段（Agent 策略层缺陷规避）。v1 主路径 = Workflow 层。
- **涉及文档**：教研workflow详细设计.md §6；poc-验证报告.md §3.2
- **建议方向**：与 F1 同源；实现时教研 workflow 的适配层同样内置多信号分批 feed 测试。

---

## 汇总统计

- 🔴 阻断级：1（F1）
- 🟡 建议 v1 内处理：4（F2、F7、F8、F11）
- 🟢 已确认/仅记录：7（F3、F4、F5、F6、F9、F10、F12）

**建议动作**：F1/F7 需 Leader 或领域建模工程师在 `docs/03-决策记录/开放问题决策清单.md` 中拍板；
F2/F8/F11 进入 v1 集成测试与实现清单。
