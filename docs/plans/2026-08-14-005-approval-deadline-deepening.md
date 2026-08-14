# 审批期限深化:ApprovalDeadline 单点 + 扫尾 specs 化

> 日期:2026-08-14 · 来源:架构评审(report 1786689868)候选② + scout 静态探查(JealousCrane,行号基于 origin/develop 无 PR-C)· 状态:已批准
> 前置:**PR-C(#139 NotificationFanout)合入后开工**(PR-D)——两者都改 approval_reminder_worker.ex,行号与收件人解析面重叠。
> 范围纪律:只动 deadline 派生语义 + AEW 扫描结构;不改任何行为(过期终态、提醒入队、通知、幂等窗口全部原样)。

## 目标

1. deadline 语义单点:`Cgc2046.ApprovalDeadline` 拥有 derive / overdue? / in_window? / 默认窗口常量——消灭 AEW(168-174)与 ARW(151-155)两份平行派生公式、4 处 `@default_approval_timeout_days 7` 常量拷贝。
2. AEW 六份 scan/expire 收敛为 specs 表驱动:`{resource, status, deadline 来源, tenant?}` 六行声明 + 一个通用扫尾函数;WorkflowRun 保留「load definition + 内存判断」派生路径。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | `ApprovalDeadline` 为 root 单文件 `lib/cgc_2046/approval_deadline.ex`(横切读取面,NotificationFanout 同款先例);**不建独立 Sweep 模块**——sweep 只有一个调用方(AEW),specs 表是 AEW 内部结构,拒绝 speculative abstraction |
| D2 | interface:`derive(record) :: DateTime \| nil`(列实体读列;WorkflowRun = updated_at + definition.approval_timeout 内存派生)、`overdue?(record, now)`、`in_window?(deadline, now, window_end)`、`default_timeout_days()`;nil 语义 = 永不过期,单点 moduledoc 写明 |
| D3 | AEW specs 形状:`%{resource:, status:, deadline: {:column, :approval_deadline \| :expires_at} \| :derived, tenant: boolean}` 六行;列实体 SQL 下推保持(不退化为全表 load);`:derived` 路径 load definition + 内存判断 |
| D4 | 每记录转换仍走各资源 `:expire` 领域 action(带/不带 tenant,D-A6 纪律);失败 warning+skip 不中断整拍——原样 |
| D5 | 4 处常量收敛:各资源 `@default_approval_timeout_days` 删除,创建期设值改调 `ApprovalDeadline.default_timeout_days()`;enrollment 客户端可传 deadline / sponsorship 服务端固定的**创建纪律不动**(两套纪律差异是超范围议题,仅 plan 记录) |
| D6 | WorkflowDefinition.approval_timeout 注释修正为实际语义(nil = 永不超时,**不引入默认值**——行为不变铁律);语义漂移在 plan 记录,是否给默认值留产品决策 |
| D7 | ARW 不并入 sweep:三份 remind scan 结构保留,只把 deadline 派生(in 151-155)与窗口判断(in_window? 157-160)改调 ApprovalDeadline;三种提醒副作用(Enrollment per-approver 入队 / Sponsorship owner-admin 差异 / Run SignalLog)形态各异,不强行统一 |
| D8 | 排除:PendingOperation(10 分钟 TTL、读时派生、不在 6 扫)、读时派生 4 处(Invitation/PendingOperation effective_status、graphql 特判、前端 ApprovalChip——兜底语义不动)、领域 action 原子守卫(approve/confirm/accept 期防过期审批,第 5 面)、cron 频率与队列 |

## 当前状态证据(scout 2026-08-14)

- AEW 六份 scan:Enrollment/JoinRequest/Sponsorship/WorkspaceApplication(78-130,{:pending, approval_deadline 列, tenant?})+ Invitation(135-143,{:active, expires_at 列, tenant})+ WorkflowRun(150-174,:waiting + 内存派生,唯一真差异点)
- 派生公式两份:AEW approval_overdue?(168-174)⇄ ARW approval_deadline(run)(151-155);ARW 另有 (now, now+48h] 窗口谓词(157-160)
- 常量 ×4:join_request.ex:27 / workspace_application.ex:27 / sponsorship.ex:30 / enrollment.ex:19;另有 workspace.ex:552 / miniprogram_code 两个 expires_at 系常量(不在本次收敛,Invitation 系)
- WorkflowDefinition.approval_timeout(workflow_definition.ex:106-110)注释称默认 7 天、实际 nil 永不超时——注释漂移
- cron:expiry */5(config.exs:110)/ reminder 17 * * * *(113),maintenance 队列,unique 窗 300s/3600s——不动
- 测试面:AEW 16 测 + enrollment_test(411-435)/sponsorship_flow_test F7(350-377)全部 perform_job + SQL backdate 造 deadline 断言终态,零引用私有函数——重构后零改动即回归证据;ARW 接线 describe 断言 worker 模块名,不受影响

## 影响面

- **新建**:`lib/cgc_2046/approval_deadline.ex` + `test/cgc_2046/approval_deadline_test.exs`
- **改**:
  - workers/approval_expiry_worker.ex——六份 scan 函数体收敛为 @expiry_specs + 通用 sweep;approval_overdue? 删除改调 ApprovalDeadline
  - workers/approval_reminder_worker.ex——approval_deadline(run)/in_window? 改调 ApprovalDeadline(**在 PR-C 基线上**,收件人解析已是 fanout)
  - events/enrollment.ex / events/sponsorship.ex / accounts/join_request.ex / accounts/workspace_application.ex——删常量,创建设值改调 ApprovalDeadline.default_timeout_days()
  - workflows/workflow_definition.ex——approval_timeout 注释修正
- **文档**:CONTEXT.md 增词条「审批期限(Approval Deadline)」(deadline 派生唯一真源 + nil 语义 + 扫尾 specs)
- 数据库 / 配置:无

## 阶段与验收

1. `ApprovalDeadline` module + 单测:列实体 derive / WorkflowRun 派生(含 definition nil、timeout nil)/ overdue? 边界(deadline == now)/ in_window? 半开区间 / default_timeout_days
2. AEW specs 化重构 → AEW 16 测零改动全绿
3. ARW 派生/窗口改调 → ARW 测试全绿(Oban 接线 describe 不动)
4. 四资源常量收敛 + workflow_definition 注释修正 → 相关 flow 测试绿
5. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
6. 验收:全部既有测试零改动绿(行为不变);grep 证明 @default_approval_timeout_days / approval_overdue? / ARW 私有 approval_deadline 派生零残留

## 风险与回滚

- WorkflowRun 派生路径若误并入纯 SQL specs 会静默失效(nil timeout 恒不过期)——specs 的 :derived 分支单测必须覆盖「timeout nil 的 run 永不被扫」
- enrollment 创建期 prepare_policy 读常量的时点(client 可传覆盖默认)——收敛只动默认值来源,不动覆盖逻辑,flow 测试守
- 回滚:单 PR revert;无迁移无部署依赖

## signoff 标准

- advisor01 check 评审 PASS(hard stops 0)
- 全量测试绿 + format/compile 干净
- 前置确认:PR-C 已合入 develop

## 人类决策记录

- 2026-08-14 用户授权「收集信息→写计划→writer01 实施→advisor01 评审」流水线;设计决策 D1-D8 依 scout 证据由 orchestrator 定稿,与评审报告候选② 方向一致(sweep 独立模块一项依证据收窄为 AEW 内部结构)
