# ADR-0010:workers/ 与 changes/ 目录收尾——归位映射与遗留缺口登记

- 状态:已接受(2026-08-29)
- 背景:ADR-0009 五步 PR 序列落地后,代码树残留两个跨域集中目录——`lib/cgc_2046/workers/`(15 个 Oban worker)与 `lib/cgc_2046/changes/`(7 个 Ash change/validation)。Fable 5 评审(ADR-0009 全量复审)要求:要么归位,要么成文登记决策与缺口。本 ADR 选择**先成文、后迁移**:ADR-0009 评审修复批已很大,目录搬迁是零行为机械操作,独立 PR 执行可回滚性更好。

## 决策

### W1:worker 归属原则 = 状态机属主域

Oban worker 不是独立关注点,是它驱动的状态机的异步执行臂。归属判定唯一问题:**这个 worker 推进的实体状态机属于哪个 context?** 属主域即归宿。

目标态映射(现行模块名 → 目标位置):

| worker | 推进的状态机 | 目标位置 |
|---|---|---|
| payment_expiry_worker / payment_refund_worker / payment_settlement_worker / payment_reconciliation_worker | payments_orders / 资金对账 | `payments/workers/` |
| reconciliation_scan_worker | reconciliation_findings | `reconciliation/` |
| approval_expiry_worker / approval_reminder_worker | enrollments(pending 审批 SLA) | `admission/workers/` ⚠️分歧 |
| offering_cancel_refund_worker | enrollments(cancelled 批量退款编排) | `admission/workers/` ⚠️分歧 |
| event_lifecycle_worker | events(到时 open/close) | `events/` (它同时管 Course——分家后名不副实;搬迁时改名 `OfferingLifecycleWorker` 或按域拆二,执行 PR 拍板)|
| curriculum_progress_worker | curriculum 产出物进度 | `curriculum/` |
| learning_progress_worker | learning_records | `learning/` |
| notification_worker | 通知投递 | `notifications/` |
| signal_publish_worker | signals outbox | `workflows/` |
| share_scheme_worker | 分享 scheme(小程序侧) | `miniprogram/`(评审序4 判定) |
| login_artifact_pruner_worker | 登录工件清理(phone_verification_codes/wechat_login_tickets) | `miniprogram/` ⚠️分歧 |

⚠️分歧三项(评审原判 vs 本 ADR 拍板,均非对错、由 product owner 定夺,执行 PR 前定稿):

- approval_expiry/reminder:本 ADR 判 `admission/workers/`(推进 enrollment 审批 SLA);评审原判**跨域**——它扫 6 类资源(含 Accounts×3/Sponsorship),见缺口⑦「审批机制族」。
- offering_cancel_refund_worker:本 ADR 判 `admission/`(取消报名编排);评审原判 **Payments**(取消→批量退款是资金反应)。
- login_artifact_pruner_worker:本 ADR 判 `miniprogram/`;评审原判 **Accounts**(清理对象是登录工件,Accounts 语义更近)。

迁移注意事项(写进执行 PR):

1. **Oban `jobs.worker` 列存模块名字符串**——模块改名后,改名前入队而未执行的 job 将无法执行。当前部署窗口用户量零/库可重置,执行 PR 合并前清空 Oban 队列或选低峰部署即可;cron 由启动时重建,无残留。队列名(QUEUE 配置)不随目录变化,运维面零漂移。
2. **规3/6 死信白名单的模块名字符串字面量三处**(复审发现,ADR-0009 批遗漏):`reconciliation_scan_worker.ex` 的 `@dead_letter_workers`(SignalPublishWorker/NotificationWorker 两串)与死信窗口查询内联的 SignalPublishWorker 一串——改名后不同步这三处,规6 将查永远不存在的旧模块名、永远零命中=永远绿,死信看护静默失效且无测试会红。搬迁 PR 必须同步这三处,并给规6 加一条「白名单模块必须真实存在」的编译期或测试期断言,杜绝复发。

### W2:changes/ 拆解——消钉不留通用层

`changes/` 作为「通用 change 收容层」是反模式:7 个模块里 6 个有明确属主域,1 个单消费方。全部归位,目录消亡:

| 模块 | 消费方 | 目标位置 |
|---|---|---|
| assign_roles | accounts/*(workspace/invitation/join_request 等) | `accounts/changes/` |
| log_admin_action | accounts/*(AdminActionLog 写点) | `accounts/changes/` ⚠️分歧(评审原判:与 SignalEmitter 同属「真跨域」) |
| validate_inviter_role_preauthorization / validate_workspace_has_owner / validate_workspace_join_policy | accounts/* 校验 | `accounts/changes/` |
| waive_pending_on_pricing_disable | Event/Course update 动作,操作 enrollments 数据 | `admission/changes/`(经 Enrollment 端口语义,挂载点在 offering 侧) ⚠️分歧(评审原判归 Offering——挂载侧;本 ADR 取数据属主侧) |
| transition | 唯一消费方 WorkflowRun | `workflows/changes/` |

先例已立:SignalEmitter 已于 Fable 5 修复批迁 `workflows/signal_emitter.ex`(信号主干归 Workflows),`changes/` 自此无信号类成员。

### G1:遗留缺口登记

> 来源说明:Fable 5 评审缺口清单原件曾随会话归档截断丢失,2026-08-29 复审(同评审者)重建原件,本节已按原件对号补全。①-⑤ 为清偿项,⑥-⑩ 与 A2-A5 为登记的开放缺口。

**已清偿(本批)**:

1. course.ex 内容读契约兼容委托删除(零调用,MCP/GraphQL 直调 `Cgc2046.Curriculum`)。
2. `capacity_changed` 幂等键 System.unique_integer **裁定保留**:消费方 state_based(按 sync_version 覆盖式幂等、不写 claim),重复投递无害;outbox 同事务入队,事务重试整体回滚;同一 offering 多次变更须各自独立去重,键集合不变仅值唯一化是正确语义。复审确认理由链完整,文档钉住即为清偿。
3. occupancy 负数防御:`admission_capacity_ledgers` CHECK `occupancy >= 0`(迁移 20260902000000,幂等可逆)。
4. 定稿设计文档字段名漂移:`research_requirements → curriculum_requirements`(两份定稿 + template-parameterization puml/svg);`DRIFT-EVIDENCE/` 历史快照不动。
5. payments_orders 逆向写点收编 `Payments.Order.void_pending_for_enrollment/2`(ADR-0009 D6 补记);StatusTransition 迁根部白名单化,offering/ 纯读零写。

**开放缺口(评审原件 ⑥-⑩,按建议执行序)**:

6. **graphql_schema.ex 单体瘦身(3202 行)**:藏着两块应用逻辑——学习投影组装(`learning_projection_sources/2` 等,`authorize?: false` 直读 Curriculum/Learning/Courses 三域)与整套注册/登录/改手机号流程(`sign_up_with_phone/4` 等 ~400 行);interface layer 长成事实上的第 13 个 context。先抽 `Learning.RunProjection` 与 `Accounts.SignUpFlow`(`accounts/sign_in_flow.ex` 已是先例),schema 分文件可缓。
7. **审批机制族命名**:`approval_claim.ex`(4 context/17 处引用)+ `approval_deadline.ex`(5 context/8 文件)+ `pending_approvals.ex`(跨 4 域 CQRS 读模型)+ 两个 approval worker,是客观存在但没名字的共享内核。最低成本:CONTEXT.md 词条明示「刻意不归任一 context」;进阶:成立 `approvals/` 收编五件。注:StatusTransition 迁根后根部横切写原语增至三件(ApprovalClaim/ApprovalDeadline/StatusTransition)+ PendingApprovals,是本缺口的扩大版,收编时一并定归宿。
8. **Offering 正名 Shared Kernel**:offering/ 下 5/6 子模块只被 Event+Course 消费——上下文映射里的 Shared Kernel(耦合最强映射),与「对 Admission 的 OHS 端口」是两种身份。§5.4 补一行显式承认,并约定「改动需两侧同时回归」。
9. **跨域 FOR UPDATE 行锁未端口化**:`payments/order.ex:689` 在 Payments 事务里锁 Admission 的 enrollments 行并依赖其 7 个列名。锁必要,但锁语义该由 Admission 发布(`Enrollment.lock_for_order/1`);实施前需针对性测试验证 Ash 事务继承下锁生命周期不变。
10. **Miniprogram 壳 domain**:三资源里两张表写权在别家——Code 写路径在 `Accounts.MiniprogramCode`、Consent 写路径在 `notifications/consent.ex` 裸 SQL(与 `miniprogram/notification_consent.ex` 同表),违反 D2「服务独占更新权」。资源跟写路径走,或服务跟资源走,二选一(拍板项)。

**复审补记(A2-A5)**:

- **A2 措辞认账**:W1 把 reconciliation_scan_worker 整体判给 `reconciliation/`(评审原稿保守路径 a,成立),但 ADR-0009 D6「扫描器归各域」原文需同步改写,否则两 ADR 矛盾——已在 ADR-0009 D6 补记。
- **A3 Learning 逻辑主体在 W1 射程外**:learning_instantiator.ex(订阅 enrollment.completed 种 run,业务规则非编排)、learning_progress.ex(进度投影+停滞口径)、agent_instructions.ex(零消费方)都在 `workflows/`——同批 Curriculum/Sponsorship/Admission 的 instantiator 都归位了,唯 Learning 例外。待办:迁 `learning/` 或在本 ADR 明示排除理由。
- **A4 内容读契约收敛**:CourseContent 形状契约仍在 `workflows/`(Curriculum 反向依赖它);`Output(kind=:issues)` 同形查询 5 处重复(curriculum/两 worker/MCP/graphql_schema),只 1 处在域内。
- **A5 §5.4 补三行**:develop 上领域模型定稿 §5.4 仍无 Offering/Integrations/Miniprogram 行,「代码目录与本表一一对应」声明失真,需补。

**「该留勿动」清单(防后续误改)**:

- Events/Courses 各一份同构 CapacityProjectionSubscriber 是**正确做法**(各写自己的表,合并反而重造跨域写点)。
- 根部 `Cgc2046.Mailer` 与 `Integrations.SendCloud.Mailer` 是 Swoosh mailer/adapter 标准两层,非重复。
- Admission 对 Event/Course 的双 belongs_to 是 Ash 关系定义的技术必然,实读全走端口;「引用形状解耦」为 deferred(ADR-0009 已补记——「双 belongs_to」正是它自己列的浅拆判据,特此对齐)。
- **M6 归宿 trade-off(钉账防误认终态)**:Accounts.SponsorshipTier 让依赖箭头顺流(方向正确),代价是赞助统一语言词汇(档位/独占位/权益)住进身份/租户上下文、Sponsorship 反向 import 自己的核心概念——**命名错位换方向正确,根治挂 B9-b**:sponsorship_tiers 列随聚合迁 `Sponsorship.TierConfig`(软引用 target_kind/target_id)后模块回家。
- **M1 覆盖面说明(可接受,不动)**:confirm 活值守卫只恢复 status 真值,registration_deadline 维度仍靠缓存——规12 已看护该列漂移。

## 后果

- workers/、changes/ 两目录的物理搬迁排入后续独立 PR(本 ADR 为唯一事实来源);搬迁 PR 只做 `git mv` + 模块前缀改 + 引用收敛,零行为变化,评审走机械核对。
- 目录消亡后,「新增 worker/change 放哪」不再有默认坑位——CONTRIBUTING 新增条目指向本 ADR 的归属原则。
- G1 登记随评审原件对齐更新;登记项清偿时划去并注 PR 号。
