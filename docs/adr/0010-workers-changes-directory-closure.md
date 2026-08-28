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
| approval_expiry_worker / approval_reminder_worker | enrollments(pending 审批 SLA) | `admission/workers/` |
| offering_cancel_refund_worker | enrollments(cancelled 批量退款编排) | `admission/workers/` |
| event_lifecycle_worker | events(到时 open/close) | `events/` |
| curriculum_progress_worker | curriculum 产出物进度 | `curriculum/` |
| learning_progress_worker | learning_records | `learning/` |
| notification_worker | 通知投递 | `notifications/` |
| signal_publish_worker | signals outbox | `workflows/` |
| share_scheme_worker | 分享 scheme(小程序侧) | 迁移时定:读其实体属主后落 Miniprogram 或 Accounts |
| login_artifact_pruner_worker | 登录工件清理 | `miniprogram/` |

迁移注意事项(写进执行 PR):**Oban `jobs.worker` 列存模块名字符串**——模块改名后,改名前入队而未执行的 job 将无法执行。当前部署窗口用户量零/库可重置,执行 PR 合并前清空 Oban 队列或选低峰部署即可;cron 由启动时重建,无残留。队列名(QUEUE 配置)不随目录变化,运维面零漂移。

### W2:changes/ 拆解——消钉不留通用层

`changes/` 作为「通用 change 收容层」是反模式:7 个模块里 6 个有明确属主域,1 个单消费方。全部归位,目录消亡:

| 模块 | 消费方 | 目标位置 |
|---|---|---|
| assign_roles | accounts/*(workspace/invitation/join_request 等) | `accounts/changes/` |
| log_admin_action | accounts/*(AdminActionLog 写点) | `accounts/changes/` |
| validate_inviter_role_preauthorization / validate_workspace_has_owner / validate_workspace_join_policy | accounts/* 校验 | `accounts/changes/` |
| waive_pending_on_pricing_disable | Event/Course update 动作,操作 enrollments 数据 | `admission/changes/`(经 Enrollment 端口语义,挂载点在 offering 侧) |
| transition | 唯一消费方 WorkflowRun | `workflows/changes/` |

先例已立:SignalEmitter 已于 Fable 5 修复批迁 `workflows/signal_emitter.ex`(信号主干归 Workflows),`changes/` 自此无信号类成员。

### G1:遗留缺口登记(评审遗留 + 本批裁定)

Fable 5 评审缺口清单原件未入库(会话归档截断),本节按当前代码可取证项重建;原件到位后对号补记。

1. **course.ex 内容读契约兼容委托(已清偿)**:KD3 迁移后 `Course.course_content/1`、`Course.issue_map_rows/1` 双委托零调用(MCP/GraphQL 直调 `Cgc2046.Curriculum`),Fable 5 修复批已删,`curriculum.ex` 注释同步更正。
2. **`capacity_changed` 幂等键 System.unique_integer(裁定:保留)**:`event.ex`/`course.ex` 的 `capacity_changed_payload` 键带逐次唯一判别子。裁定理由:消费方 CapacityProjectionSubscriber 为 state_based(按 sync_version 覆盖式幂等,不写 claim),重复投递无害;outbox 同事务入队,事务重试整体回滚不产生重复;同一 offering 多次变更必须各自独立去重,键集合不变仅值唯一化是正确语义。代码注释已载明,不再动。
3. **occupancy 负数防御(已清偿)**:`admission_capacity_ledgers` 增 CHECK `occupancy >= 0`(迁移 20260902000000,NOT VALID + VALIDATE 两步,幂等可逆),守卫失效从静默腐蚀升级为事务报错。
4. **定稿设计文档字段名漂移(已清偿)**:`research_requirements → curriculum_requirements` 在 `课程issue学习闭环详细设计.md`、`教研workflow详细设计.md`、`template-parameterization.puml`(svg 已重渲染)同步;`DRIFT-EVIDENCE/` 为历史快照不动。
5. **payments_orders 逆向写点(已清偿)**:Enrollment 直写裸 SQL 收编为 `Payments.Order.void_pending_for_enrollment/2`(ADR-0009 D6 补记)。
6. **StatusTransition 驻留 offering/(已清偿)**:写原语迁根部 `Cgc2046.StatusTransition`,table 参数收窄 atom 白名单,offering/ 目录纯读零写(CONTEXT.md 词条已更正)。

## 后果

- workers/、changes/ 两目录的物理搬迁排入后续独立 PR(本 ADR 为唯一事实来源);搬迁 PR 只做 `git mv` + 模块前缀改 + 引用收敛,零行为变化,评审走机械核对。
- 目录消亡后,「新增 worker/change 放哪」不再有默认坑位——CONTRIBUTING 新增条目指向本 ADR 的归属原则。
- G1 登记随评审原件对齐更新;登记项清偿时划去并注 PR 号。
