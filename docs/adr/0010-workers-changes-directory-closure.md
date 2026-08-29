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
| share_scheme_worker | 分享 scheme(小程序侧) | `miniprogram/`(product owner 裁定 2026-08-29:22 行薄壳,唯一依赖 Miniprogram.ShareSchemeService,属主明确) |
| login_artifact_pruner_worker | 登录工件清理(phone_verification_codes/wechat_login_tickets) | `accounts/workers/`(⑩ 方案A 落地 2026-08-29,采纳评审原判) |

⚠️分歧三项(评审原判 vs 本 ADR 拍板,均非对错、由 product owner 定夺,执行 PR 前定稿):

- approval_expiry/reminder:本 ADR 判 `admission/workers/`(推进 enrollment 审批 SLA);评审原判**跨域**——它扫 6 类资源(含 Accounts×3/Sponsorship),见缺口⑦「审批机制族」。
- offering_cancel_refund_worker:本 ADR 判 `admission/`(取消报名编排);评审原判 **Payments**(取消→批量退款是资金反应)。
- login_artifact_pruner_worker:本 ADR 判 `miniprogram/`;评审原判 **Accounts**(清理对象是登录工件,Accounts 语义更近)。**⑩ 方案A 落地时采纳评审原判,已迁 `accounts/workers/`(2026-08-29)**。

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
5b. **规12 宽限锚点缝隙(2026-08-29 清偿)**:删规12 的 `l.updated_at < NOW()-600s` 宽限谓词——reserve/release 的 `SET updated_at=NOW()` 不占缓存列却刷新锚点,报名活跃的 offering 永不告警(恰是超卖风险最高者)。改「缓存≠真值即出 finding」,在途瞬时命中由刷新语义下一拍自消(规8 先例)。`@drift_grace_seconds` 还原为规10 专属;规10 同构锚点问题(纯缓存写也刷 updated_at)仍为 LOW 挂账,语义纠缠未动。

**开放缺口(评审原件 ⑥-⑩,按建议执行序)**:

6. **graphql_schema.ex 单体瘦身——已清偿(2026-08-29,`06e0074`)**:学习投影组装抽 `Cgc2046.Learning.RunProjection`(公开入口 `project_run/3`,#217 锚链守卫头注随迁);注册/登录/改手机号/密码重置 + 限流函数族抽 `Cgc2046.Accounts.WebAuthFlow`(命名取舍:非纯 sign-up,按 sign_in_flow.ex 先例取 flow 名;moduledoc 写清与 SignInFlow 分工)。graphql_schema.ex 3196→2771 行(-425),SDL 零 diff;7 个 error code 字面量随迁致 `priv/error_codes_contract.json` 按契约测试指引再生成(纯 +7 无删除)。schema 分文件仍缓(非缺口)。
7. **审批机制族命名——已清偿(2026-08-29,本批 docs commit,取最低成本路径)**:CONTEXT.md 新增「审批机制族」词条,明示 ApprovalClaim/ApprovalDeadline/StatusTransition/PendingApprovals 为横切共享写原语与读模型、**刻意不归任一 context、根部驻留**;进阶 `approvals/` 收编维持开放选项,未拍板不动。
8. **Offering 正名 Shared Kernel——已清偿(2026-08-29,本批 docs commit)**:领域模型定稿 §5.4 已补 Offering 行(shared kernel;纯读零写、无状态无表;改动需 Events/Courses 两侧同时回归)。
9. **跨域 FOR UPDATE 行锁未端口化——已清偿(2026-08-29,`59edcdc`,test-first)**:`Enrollment.lock_for_order/1` + `workspace_id_for_order/1` 发布于 Admission,SQL 原样内迁、返回形状逐键不变;Order 四处调用点改一行委托。钉测 `order_enrollment_lock_test.exs`(先写于现代码即绿、搬迁后仍绿)确定性编排「持锁方确认 → 竞争下单获锁重读 status 拒单、零订单落库」(pg_locks 取证阻塞;教训:sandbox shared 下持锁事务必须 unboxed,否则只是 savepoint 锁不释放)。锁生命周期经钉测验证无可观测差异。
10. **Miniprogram 壳 domain——已清偿(2026-08-29,本批 commit,方案 A:资源跟写路径走,product owner 拍板)**:`Miniprogram.Code` → `Accounts.InvitationCode`(表 `invitation_codes`;语义更准——本质是 Invitation 渠道码缓存,写方 `Accounts.MiniprogramCode` 同域);`Miniprogram.NotificationConsent` → `Notifications.NotificationConsent`(表 `notification_consents`,mp_ 前缀名不副实——支持 wechat/tt/xhs 三平台;与唯一写方 `Notifications.Consent` 裸 SQL 同域,SQL 形态不变只改表名);`login_artifact_pruner_worker` → `accounts/workers/`(crontab 同步);Miniprogram domain 收缩至仅 ShareScheme。连带新建 `Cgc2046.Notifications` Ash domain(此前该 context 无 domain 模块;无 GraphQL 面,同 Mcp 先例),ash_domains config 与 domains_test 精确集合同步。表改名 migration `20260903000000` 纯 rename 保数据、up/down 对称,resource_snapshots 目录与 JSON 同步更名。

**复审补记(A2-A5)**:

- **A2 措辞认账**:W1 把 reconciliation_scan_worker 整体判给 `reconciliation/`(评审原稿保守路径 a,成立),但 ADR-0009 D6「扫描器归各域」原文需同步改写,否则两 ADR 矛盾——已在 ADR-0009 D6 补记。
- **A3 Learning 逻辑主体在 W1 射程外——已清偿(2026-08-29,`872d143`)**:三模块迁 `learning/`——`Learning.LearningInstantiator`(leaf 保留 `learning_instantiator`,SignalSubscriber consumer_key 契约与幂等 claim 键不变)、`Learning.Progress`、`Learning.AgentInstructions`(零消费方种子语义不变);引用收敛(curriculum.ex / mcp get_course_content / application.ex / graphql_schema.ex / reconciliation 两文件);测试镜像随迁。
- **A4 内容读契约收敛——已清偿(2026-08-29,`0a81d1a`)**:`CourseContent`(+Validation)迁 `curriculum/content.ex`(`Cgc2046.Curriculum.Content*`);五处同形查询收敛为 `Curriculum.content_output/2` 单一入口——语义比对结论:核心查询逐字同构(filter+limit(1)+read_one+authorize?: false+tenant),差异仅结果包装(data 解包/错误原子/字符串错误各调用方自持),零行为变化。
- **A5 §5.4 补三行——已清偿(2026-08-29,本批 docs commit)**:Offering(shared kernel)/ Integrations(ACL/infra)/ Miniprogram(channel supporting)三行已补;「一一对应」声明按终态修正(根部横切写原语为例外并指向 CONTEXT.md 词条)。

**「该留勿动」清单(防后续误改)**:

- Events/Courses 各一份同构 CapacityProjectionSubscriber 是**正确做法**(各写自己的表,合并反而重造跨域写点)。
- 根部 `Cgc2046.Mailer` 与 `Integrations.SendCloud.Mailer` 是 Swoosh mailer/adapter 标准两层,非重复。
- Admission 对 Event/Course 的双 belongs_to 是 Ash 关系定义的技术必然,实读全走端口;「引用形状解耦」为 deferred(ADR-0009 已补记——「双 belongs_to」正是它自己列的浅拆判据,特此对齐)。
- **M6 归宿 trade-off(钉账防误认终态,保持挂账,评估缓办 2026-08-29)**:Accounts.SponsorshipTier 让依赖箭头顺流(方向正确),代价是赞助统一语言词汇(档位/独占位/权益)住进身份/租户上下文、Sponsorship 反向 import 自己的核心概念——**命名错位换方向正确,根治挂 B9-b**:sponsorship_tiers 列随聚合迁 `Sponsorship.TierConfig`(软引用 target_kind/target_id)后模块回家。
- **M1 覆盖面说明(可接受,不动)**:confirm 活值守卫只恢复 status 真值,registration_deadline 维度仍靠缓存——规12 已看护该列漂移。
- **规10 同构锚点(LOW,保持挂账,评估缓办 2026-08-29)**:sync_from_offering 纯缓存写也刷 updated_at,频繁编辑清零投影漂移计时;语义纠缠不进清偿批。
- **「保存失败」无字段名提示(保持挂账,评估缓办 2026-08-29)**:赞助档位保存的错误提示体验,键名错配修复(异常①)时已明示不随批。

## 后果

- workers/、changes/ 两目录按本 ADR 映射完成物理搬迁(**实施状态:2026-08-29 已执行**,单 PR 双 commit——W2 changes/ 先行、W1 workers/ 随后;规6 白名单三处字符串随迁,并加「白名单模块必须真实存在」测试断言)。
- 目录消亡后,「新增 worker/change 放哪」不再有默认坑位——CONTRIBUTING 新增条目指向本 ADR 的归属原则。
- G1 登记随评审原件对齐更新;登记项清偿时划去并注 PR 号。
