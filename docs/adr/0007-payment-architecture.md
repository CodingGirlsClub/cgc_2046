# ADR-0007: 缴费架构——平台统一商户号 + 占位限时支付

> 日期：2026-08-15 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（product owner）
> 关联：缴费 grilling 2026-08-15（13+7 项拍板，本 ADR 固化其中两项结构性决策）、赞助文档预留插桩点（`payment_pending → paid`，`docs/01-定稿设计/赞助workflow详细设计.md` §3.3；历史设计文档，已归档于 git 历史）、Enrollment 并发不变量（`confirmed_count` 条件 UPDATE；2026-11-22 补记：已随 ADR-0009 PR⑤ U6 演进为 `Cgc2046.Admission.CapacityLedger` 的 `occupancy` 条件 UPDATE，`confirmed_count` 退为异步投影缓存）
> 取代：Learner Q3「报名全免费」约束（`docs/03-决策记录/grill-决策记录-2026-08-01.md`；历史设计文档，已归档于 git 历史）——免费仍是默认，收费为可选路径。

---

## 背景（Context）

- 活动/课程（Event/Course）上线报名后缺缴费闭环；用户已具备微信支付 + 支付宝双商户资质。
- 平台是多租户的（各 CGC 分会各办活动），商户资质却只有一个主体；资金归属必须先定，否则 Payments 配置模型无从设计。
- 报名已有强占位机制（`confirmed_count` 原子扣减 + 部分唯一索引防重复），支付如何嵌入而不破坏该不变量是核心问题。

## 决策（Decision）

1. **平台统一商户号。** 全平台共用一套微信支付 / 支付宝商户资质，平台是资金责任主体；各 Workspace 收款进平台账户，与分会线下结算。不做 per-workspace 支付配置。
2. **占位 → 限时支付。** 收费活动报名时先原子占名额（复用 `confirmed_count` 条件 UPDATE；**2026-11-22 补记**：随 ADR-0009 PR⑤ U6 落地，原子占座真源已迁至 `Cgc2046.Admission.CapacityLedger` `backend/lib/cgc_2046/admission/capacity_ledger.ex` 的 `occupancy` 单行条件 UPDATE，Event/Course 上的 `confirmed_count` 改为由 `capacity.synced` 驱动的异步投影缓存），Enrollment 进入 `payment_pending` 并生成限时订单（默认 2 小时，订单截止 = `min(下单 + 时限, registration_deadline)`）；支付回调成功才 `confirmed`，超时未付自动释放名额（报名转 `expired`）。
3. **迟到支付一律原路退款。** 订单过期后渠道侧才完成的扣款，自动原路全额退回——钱账一致是硬约束，不存在"过期还落账"分支。
4. **退款即取消报名。** 全额退款同时取消 Enrollment 并释放名额，不产生"退钱占坑"。

### 拒绝的替代

- **per-workspace 商户号：** 分会多为非独立法人主体，资质与配置成本高，且未配置商户号的工作台无法开收费活动；平台统一收款 + 线下结算符合社区治理现实。未来分会自带资质时加 per-workspace 覆盖配置，不推翻本骨架。
- **支付成功才占位（pay-then-confirm）：** 名额与收款强一致、无占位超时问题，但热门活动在付款瞬间名额被抢会触发"已收款却报不上名 → 被动退款"，报名体验割裂；占位制的名额吊死风险由限时订单 + 超时释放解决。

## 后果（Consequences）

- **正面：** 多租户 + 单资金主体的配置最简（全局一套密钥）；免费活动（`pricing_enabled: false`）报名路径与现状完全一致，零回归面；`confirmed_count` 机制不动，超卖防护延续。
- **代价/风险：**
  - Enrollment 状态机插入 `payment_pending`（正是赞助文档预留的二期插桩位置）：唯一索引 where 子句、容量计数、过期扫描 worker、用户取消 action 的适用状态均需覆盖该态。
  - 名额在 `payment_pending` 期间被"吊住"（最多 2 小时），热门活动周转率略降——接受，换"先到先占"的公平性。
  - 平台 Admin 需持退款兜底权（资金主体对资金操作的最终责任），跨租户特权面再 +1。
  - 平台与分会的线下结算依赖人工纪律，系统外流程（对账扫描可提供数据支撑，不做自动分账）。

---

## 更正补记（2026-09-14 实施期）——押金制：`forfeited` 为首个「终态且不退」语义

> 正文与三条决策不改，本节为实施期更正与补充（先例：ADR-0009 D2/D6/D8、ADR-0010 G1 的补记写法）。实施载体：`docs/plans/2026-09-14-1357-feat-event-deposit-plan.md`（R6–R9、KTD7、KTD8；接管 #509 押金语义落点与自动结算）。

1. **新增 Order 终态 `forfeited`（`paid → forfeited`，一次性 CAS）。** 活动正常结束（锚点只认 `ends_at`）+ 48h 后仍未核销（无 Attendance 行）的 `paid` 押金单，由 `Cgc2046.Payments.Workers.DepositForfeitWorker` 结算为 `forfeited`：**押金不退、留作平台收入**，参与者事前文案明示「未到场不退」（`workspace_payment_stats` 增 `forfeited` 桶供对账导出）。**这是本 ADR 之外的第一条「钱不原路退回」的资金去向**——决策 3、4 都隐含「退款是唯一资金出口」（迟到支付全退、退款即取消），`forfeited` 明确「不退款也是合法终态」，故补记于此；资金去向的财务细则（开票义务、收入确认时点、科目）沿 #509 R4 另行确认。（**2026-11-22 补记**：`#545` 随后为 `forfeited` 引入平台管理员救济转移 `Order :unforfeit`（`forfeited → refunding`，见 `backend/lib/cgc_2046/payments/order.ex` 与 `AdminActionLog :order_unforfeit`），用于异常申诉场景下的人工原路退回。）

2. **决策 4「退款即取消报名」射程收窄为一般路径。** 到场事实（Attendance 行存在 ⇔ 该报名被核销过）或免缴留痕在场时，退款**保留** confirmed 报名、不释放名额，`PaymentRefundWorker.cancel_enrollment/1` 以持久事实判定（读失败 fail-closed 上抛，绝不折叠为「未到场」）。到场即占位——退款不得撤销已发生的到场；此例外为核销即退（Attendance 落行同事务发起全额退款）与免缴路径的前提。no-show 结算只推进 Order 终态、不编排 Enrollment，报名保持 `confirmed`。

3. **押金不改变决策 1–3 的骨架。** 平台统一商户号、占位 → 限时支付原样复用（押金单 `order_kind = :deposit`，金额源为报名提交时物化的押金快照）；`forfeit` 仅接受 `paid` 源态，过期单的迟到扣款仍走 `start_refund` 全退（钱账一致硬约束不变）；退款路径互斥仍由决策 4 的 CAS 纪律承担——六条发起方（自助取消 / 活动取消批量退 / 迟到支付退 / 管理员退款 / 核销即退 / no-show 结算）共经 `start_refund`、`forfeit` 条件 UPDATE 单一仲裁点，`num_rows = 0` 即他路接管；「取消 / 未达成班无条件全退优先」由源态与 Event 状态机保证，不建独立优先级分派器（KD3、KTD8）。

---

## 补记（2026-09-24 #845）——退款发起单一入口 `RefundCommencement`

> 正文与前两条补记不改。架构评审 2026-09-24 候选 C2（Strong）落地：自动或用户侧发起的退款（自助取消 / 活动取消批量退 / 迟到支付退 / 核销即退——`start_refund` / `retry_refund` 路径）统一走 `RefundCommencement.commence/2` 这一个入口；此前的「推进到 `refunding` + 同事务入队 `PaymentRefundWorker` + 竞态收敛」在五处调用方各写一遍、错误形状刻意不同（missed fix 事故注释与指向已删函数的注释为就地证据）。管理员退款 / `unforfeit` / no-show 结算走各自治理 action，不经本入口。

1. **入队归 Order（恰好一次由设计保证）。** `:start_refund` 补上 `after_action` 入队（`enqueue_refund_job/2`），与 `:retry_refund`、`:refund`、`:unforfeit` 一致——任何进入 `refunding` 的迁移都在同一 action 事务内恰好入队一次；CAS 失败无 `after_action`，不产生孤儿 job。调用方手动 `Oban.insert!` 全部删除，此前「恰好一个任务靠 Oban unique 兜底」不再是设计依赖。

2. **`Cgc2046.Payments.RefundCommencement.commence/2` 是自动 / 用户侧退款发起（`start_refund` / `retry_refund` 路径）的唯一入口**——管理员单笔 `refund` / `retry_refund`、`unforfeit`、no-show `forfeit` 走各自的治理 action，不经本入口。 按状态分派 `start_refund`（`paid`/`expired`/`cancelled`，对齐 CAS 源态守卫）与 `retry_refund`（`refund_failed`），eligible 白名单由调用方传入；CAS 输了只用一种办法——重读一次、重新分类（状态未变透传原始错误）。`refunding`/`refunded` 恒为 `{:ok, :already_in_progress}`（race 契约在 seam 上定义一次）；seam 不替调用方决定结果处理（抛错/跳过/回滚留在调用方），各调用方的对外错误 code 与结果形状逐项不变。

3. **`deposit_settlement_race` 错误码曾保留但无抛出点，#861 已删除。** 迁移前实测：自助取消侧该 raise 分支不可达，竞态实际透出 `order_already_processed`。R1 审查更正机制认知：不可达的根因不是「case 子句匹配不上 Ash 错误类 struct」（那只是伴随症状 `CaseClauseError`），而是 Ash 默认 `rollback_on_error?: true`——嵌套 action 失败即回滚外层事务，重读收敛逻辑根本执行不到。R1-#1 修复（`rollback_on_error?: false`，产品拍板 A）后重读真正执行：已收敛 → 自助取消/核销由失败改为成功（有意行为修复），未收敛 → 上抛回滚、code 不变。（2026-09-27 #861 处置：triage 决定删码——已收敛情形改为取消成功属良性，未收敛透传 `order_already_processed`，无启用场景；`domain_error_code`/`domain_error_message` 子句与 #241 契约条目已随删，web/小程序经 git 历史核实从未配过此键文案，未来如需显式竞态语义须重新登记错误码。）

4. **变化：旧 D(a)（结算自动退款）竞态路径的补插删除（#862 对账检测）。** 旧 D(a) 的 `enqueue_auto_refund/1` 在 CAS 未命中且 reload 见 `refunding`/`refunded` 时会手动补插退款 job——发起方 action 自带 `after_action` 入队后，他路的 job 必然已存在，该补插为冗余防御，随 D1 删除（旧 C 流程只扫 `paid` 订单，从来不会补插；自助取消侧读时已 `refunding` 的补插同批删除）。代价：`refunding` 单若因运维原因丢失 in-flight job，不再有调用方补插自愈——由 #862 的对账检测承接。

---

## 更正补记（#749）——押金金额源：活动现值，创单后钉死为订单快照

> 正文与既有补记不改，本节只更正 2026-09-14 补记第 3 条的一处措辞（写法先例见该补记首段）。

2026-09-14 补记第 3 条写的「金额源为报名提交时物化的押金快照」已被 #749 取代，**该句保持原样不动，以本节为准**：押金金额以**活动现值**为权威——`Enrollment.depositAmountCents` / `paymentMode` 是计算字段，每次读都取活动当下配置，`submission_payload` 不再物化也不参与金额（历史预埋的脏键天然免疫）；创单（`createOrder`）时才把金额钉死进订单的 `tier_snapshot`，此后不随活动改价追溯已创建订单。术语：创单前 = 活动现值，创单后 = 订单快照（见 `GLOSSARY.md` §9 易混清单）。落账链、`forfeit` / `start_refund` 的仲裁纪律与第 3 条其余部分不受影响。

---

## 补记（2026-11-19）——LLM 独立收银台（llm_payment_orders）：不占位迟到可入账、已入账算力不退、关单迟付必告警

> 正文与前述补记不改。本节记录 LLM Gateway 算力收银台（`llm_payment_orders` / `LlmPaymentSettlementWorker`）复用平台统一商户号时的资金语义边界，明示其与报名支付（`payments_orders`）的有意差异与钱账一致底线。

1. **共用平台统一商户号，经 `LLM_` 商户单号前缀隔离路由。** LLM 算力订阅、加油包与工作台算力池充值独立落表 `llm_payment_orders`，与报名支付 `payments_orders` / `PaymentSettlementWorker` 零耦合，但共用平台统一微信支付 / 支付宝商户资质与回调入口（`PaymentWebhookController`）。回调入口按 `out_trade_no` 的 `LLM_` 前缀将支付通知分流到 `LlmPaymentSettlementWorker`，并显式排除退款通知（如微信 `REFUND.*` / `out_refund_no` / `refund_id` / `refund_status`、支付宝 `refund_fee` / `gmt_refund`），避免退款通知误入算力入账链。

2. **不占位故 `pending` 迟到可入账；已入账虚拟算力不退。** 算力订单不占用活动名额/库存，`expires_at` 仅作收银台展示截止时间，不挂超时作废 worker——仍处于 `pending` 的订单即使在展示截止后收到渠道已付回调，仍按原订单快照 `credits_mc` 正常 CAS 为 `paid` 并入账。虚拟算力一经入账（`paid`）即不可自助/自动退款（不接入 `RefundCommencement` / `PaymentRefundWorker`），成为本 ADR 下继押金 `forfeited` 之后第二条明确「不自动退款」的合法终态语义。

3. **已关单（`cancelled` / `expired`）收到渠道已付回调必须告警对账，守住钱账一致底线。** 若订单因渠道创单失败已标记为 `cancelled`（或经运维/策略置为 `expired`）后，渠道侧仍完成扣款并送达已付回调，`LlmPaymentSettlementWorker` **禁止**补发算力，亦不得把订单状态翻回 `paid`；必须记录 `Logger.error` 并落单事件拍 `:llm_closed_order_paid` 对账发现（`Finding.apply_rule(..., sweep: :one_shot)`，携带 `order_source`、`out_trade_no`、`status`、`amount_cents`、`transaction_id`），交人工核对后原路退款，确保「渠道已收款而未给算力」不会静默吞没，守住钱账一致硬约束。

## 参考

- `backend/lib/cgc_2046/payments/order.ex`
- `backend/lib/cgc_2046/payments/refund_commencement.ex`
- `backend/lib/cgc_2046/admission/enrollment.ex`
- `backend/lib/cgc_2046/admission/capacity_ledger.ex`
- `backend/lib/cgc_2046_web/controllers/payment_webhook_controller.ex`
- `backend/lib/cgc_2046/llm_gateway/payment_order.ex`
- `backend/lib/cgc_2046/llm_gateway/workers/llm_payment_settlement_worker.ex`
