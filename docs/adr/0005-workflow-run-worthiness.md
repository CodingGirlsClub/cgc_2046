# ADR-0005: Workflow 形态判据——实体自序贯优先，WorkflowRun 需证成

> 日期：2026-08-12 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：ADR-0002（workflow-first + Jido）、ADR-0003（pi 启发架构重构）、docs/plans/2026-08-12-001-feat-workflow-run-worthiness-plan.md、docs/ideation/2026-08-12-course-event-slice-e-ideation.html、docs/01-定稿设计/报名workflow详细设计.md（DAG 部分退稿）
> 触发：slice E 开工前，报名 workflow 面对「所有业务 workflow 都该引擎化」的未检验假设——Enrollment context 已全量建成且自我序贯，定稿 DAG 的接线零增量不变量。

---

## 背景（Context）

- ADR-0002 确立 workflow-first：WorkflowDefinition + WorkflowRun 为核心。slice C 交付了引擎与教研 workflow（research），slice E 要落地报名/赞助/邀请/学习四个业务 workflow。
- 报名详细设计（v1.4 定稿）把报名建模为 DAG（报名段 S1-S8 + 审批段 A1-A5，含审批两段式）。但在设计之后，Enrollment 业务 context 已全量建成：并发不变量由 DB 条件 UPDATE、partial unique index、action 事务承担（`backend/lib/cgc_2046/events/enrollment.ex:3-10`），confirm/reject 已在 after_transaction 发信号（:130-134, :147-151）。
- 审批两段式的「persist_pending 停住 → approval_gate 读回」由资源行的 `status=pending` 天然表达——**资源行即 pending checkpoint**，引擎的 hibernate/checkpoint 对此是重复表达。
- ideation 独立验证（2026-08-12，两路径均 sound）：引擎化接线买不来任何 Enrollment 尚未原子化强制的不变量，只买来 journal/StepAuthorization 可观测性，而 `Enrollment.status` 已表达同一时间线。
- 若每个 workflow 默认上引擎，赞助/邀请/学习将逐个重开「要不要 run」的辩论，没有判据可查。

## 决策（Decision）

1. **默认实体自序贯（entity-driven），WorkflowRun 需证成。** 新 workflow 的默认形态是：业务 context 的 Ash action 事务承担状态机与不变量，信号经 after_transaction 直发订阅方。引擎化需要至少一项证成理由：
   - 跨角色编排（≥2 方按序协作，如赞助的意向→审批→生效）；
   - 定义需多实例复用（如教研 workflow 一定义多 Event/Course 实例，D-A2）；
   - 分支/子 workflow 拓扑（单 DAG 无法被实体状态机表达）；
   - 超出实体 policy 的分步授权（StepAuthorization 粒度）。
2. **判负条件（全部满足 → 实体自序贯）：** 单 context 状态机、DB 已强制全部并发不变量、after_transaction 信号可达全部订阅方。任一不满足 → 引擎化。
3. **报名为先例：** 报名 workflow 采用实体自序贯，定稿 DAG 退稿（见报名详细设计文档状态行）；补发 `enrollment.submitted/completed` 信号，审批入口仍是网站后台审批页（#3 不变）。
4. **审批两段式保留：** 赞助/邀请无自序贯实体且含两个顺序人工信号，继续引擎化并走两段式（F1 死锁规避）。本决策退稿的是报名 DAG，不是两段式模式。
5. **「实体自序贯」收入总纲 §6 模式库**，与「审批两段式」「SignalMatch 门控」并列，作为第三种正式模式（引擎化 / 引擎化+两段式 / 实体自序贯）。
6. **config-not-code 的旗舰证明移到赞助：** 赞助资源与 DAG 都需新建，是「业务 workflow = 数据」论点的更好证明场景；报名不为此付仪式成本。

### 拒绝的替代

- **报名仍引擎化（seed :enrollment 定义）：** 与定稿零冲突、证明 config-not-code，但零增量不变量、付出定义种子 + 实例化器 + 两段式接线 + run 生命周期的整套成本，且可逆性差（run 在飞难拆）。证明目标由赞助承担更合适。
- **不设判据、逐 workflow 即兴决定：** 每个 workflow 重开辩论，形态选择随当时情绪漂移。
- **判据措辞中立（无默认倾向）：** 默认实体自序贯与证据方向一致（DB 不变量层已是本仓库纪律），中立措辞会把每次评估变成重新权衡。

## 后果（Consequences）

- **正面：** slice E 每个 workflow 的形态决策变查表；报名立即解锁学习触发（`enrollment.completed`）与提醒覆盖；设计词汇扩充，「不引擎化」是有名字的正式模式而非妥协。
- **代价/风险：**
  - workflow-first 叙事收紧为「workflow-where-it-earns」——引擎的适用范围缩小到真正需要编排的 workflow，ADR-0002 的解读随之更新。
  - 报名放弃统一 journal/StepAuthorization 可观测性；`Enrollment.status` + SignalLog + 审批审计字段承担审计。
  - 判据的证成理由若写宽会边缘化引擎，写窄会回到一切上引擎——措辞以本文件为准，修订走新 ADR。
  - 判据在赞助设计上首次接受检验；赞助形态评估结论应回写总纲 §6 条目作为第二个先例。
