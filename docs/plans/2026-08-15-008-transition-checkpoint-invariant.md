# 状态迁移深化:Transition change(workflow_run 专用)+ checkpoint 清理 invariant 补漏

> 日期:2026-08-15 · 来源:架构评审(report 1786689868)候选⑤ + scout 静态探查(SelfishShark,HEAD 784f689)· 状态:自治流水线批准
> 范围纪律:**不做 17 份守卫全量抽象**(scout deletion test:净删 ≈0、选项面 ≈ 被替换物,负收益);只收 workflow_run ×9 的状态守卫 + checkpoint 清理配对。event/course ×3+3(与 status_transition CAS 纠缠)、workflow_definition ×2(太琐碎)不抽。enrollment/sponsorship/speaker 条件 SQL 守卫是 ADR-0005 本体,不动。

## 目标

1. `Cgc2046.Changes.Transition` change 模块:`transition(cs, from:, to:, cleanup_checkpoint:)` 声明式收 workflow_run 九个状态迁移 action 的守卫——错误串格式不变(17 份内已统一:小写、动作名插值)。
2. **checkpoint 清理从隐藏 invariant 变结构保证**:scout 证实 cancel/expire 逐字两份(408-418/446-456),而 **complete/fail 两个可自 waiting 达终态的 action 缺清理**(invariant 实际违约 ×2,靠 speaker_invitation.ex:727-736 外部补偿兜着)——Transition 的 cleanup_checkpoint: true 让终态清理成为声明,补上 complete/fail,删外部补偿(clean cutover,不留兼容层)。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | Change 模块 `Cgc2046.Changes.Transition`(与 SignalEmitter 同目录同款形态),interface:`transition(changeset, from: [atom], to: atom, cleanup_checkpoint: boolean)`;before_action 阶段:status ∈ from → force_change :status,否则 add_error(错误串逐字保持现有格式「cannot <verb> from status=<s>」) |
| D2 | 只迁移 workflow_run ×9(start/wait/resume/complete/fail/cancel/expire/succeed 类);守卫语义与 from 列表逐字对照现状,不变 |
| D3 | checkpoint 清理:cancel/expire 现有 after_transaction 两份逐字拷贝收进 Transition(cleanup_checkpoint: true 时挂 after_transaction);**complete/fail 补 cleanup_checkpoint: true**(修违约);start/resume 等非终态 false 或缺省 |
| D4 | speaker_invitation.ex:727-736 外部补偿删除(Transition 已内建,补偿冗余);确认补偿删除后 fail 路径 checkpoint 清理由 Transition 承担——这是本 PR 唯一有意行为变化,PR body 声明 |
| D5 | 清理幂等性验证:现有 cleanup helper(705-713)的删除语义(按 run id 删 checkpoint 行)天然幂等;complete/fail 新增清理不与任何现存路径冲突(scout 证实此前无清理) |
| D6 | 错误串零变化:17 份格式已统一,Transition 生成的错误串逐字一致;workflow_run_test 98-349 全部 `{:error, _}` 无消息断言,零改动即证据 |
| D7 | 新增测试(本 PR 有新契约):complete/fail 后 checkpoint 被清理(参照 human_step_test 290-296 cancel 的端到端形状);Transition 模块单测(from 匹配/不匹配/cleanup 开关) |

## 当前状态证据(scout SelfishShark)

- workflow_run 九守卫(235-465)+ cancel/expire after_transaction 两份(408-418/446-456)+ cleanup helper(705-713);complete(347-364)/fail(367-384)缺清理
- 违约证据:speaker_invitation.ex:727-736 外部补偿 fail 不清理 checkpoint
- event/course 守卫嵌于 before_action + status_transition CAS(487-495/452-460),与 SignalEmitter change 组合——纠缠深,不抽
- 测试面:workflow_run_test 98-349 零消息断言;human_step_test 290-296 cancel→checkpoint 删除端到端;event_lifecycle_test 73/80/141 三条精确断言(不动 event/course 则不碰)

## 影响面

- **新建**:lib/cgc_2046/changes/transition.ex + 单测
- **改**:workflow_run.ex(九 action 改声明式组合 + 删两份 after_transaction 拷贝)、speaker_invitation.ex(删外部补偿)
- 测试:workflow_run/transition 零改动 + 新增 D7 两条
- 数据库/配置:无

## 阶段与验收

1. Transition change + 模块单测 → 守卫/清理契约绿
2. workflow_run 九 action 迁移 → workflow_run_test 98-349 零改动全绿
3. complete/fail 补清理 + speaker 补偿删除 → 新测试绿 + speaker_flow 全绿
4. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
5. 验收:既有测试零改动绿;grep workflow_run 无手写 status case 守卫残留(九 action);cancel/expire after_transaction 两份拷贝归一

## 风险与回滚

- complete/fail 新清理若与引擎内部 checkpoint 生命周期冲突(journal 回放需要 checkpoint?)——对照 ADR-0002 checkpoint 语义:checkpoint 只在 waiting 挂起期有意义,终态后无消费方;human_step cancel 端到端形状佐证
- 错误串漂移:Transition 模板必须逐字对照任一现有守卫;run_test 无消息断言 + event 侧不动,防线足够
- 回滚:单 PR revert

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → 常设规则合并

## 人类决策记录

- 2026-08-15 用户夜间授权自治流水线;scout deletion test 否决全量抽象,缩窄为 workflow_run 专用 + invariant 补漏;D4 是唯一有意行为变化(invariant 修复),PR body 声明
