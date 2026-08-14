# Instantiator 建 run 协议:find_or_create_and_start 内化 ordering invariant

> 日期:2026-08-14 · 来源:架构评审(report 1786689868)候选⑦ + scout 静态探查(QuerulousOwl,HEAD 8c3f047)· 状态:自治流水线批准
> 范围纪律:只内化「create→start 顺序 + 租户传播 + 非终态去重」的 ordering invariant;instance_key 派生、前置守卫、start 后副作用全部留调用侧。**不做大收拢**(scout deletion test:全量收拢是复杂度转移而非集中)。

## 目标

`WorkflowRun.find_or_create_and_start/4` 模块函数成为建 run 唯一入口:三个 instantiator 不再各自手写两步五参舞蹈——「漏掉 start = 永久 pending run」这一 ordering leak 从 interface 里根除(E-10 对账规则⑤要兜的失败面收窄)。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **模块函数,不是 Ash action**:异步实例化走 `authorize?: false`,带策略的 Ash action 不适用;与 workflow_run.ex 既有公开面(get_by_id/update_facts_for_mcp 等模块函数)同款 |
| D2 | 签名:`WorkflowRun.find_or_create_and_start(workspace_id, definition, input, opts)`,opts: `key:`(去重键,nil = 不去重直接 create+start,供 speaker)、`actor:`(透传)。返回 `{:ok, run, :existing \| :created}` 或 `{:error, term}` |
| D3 | 行为契约:① key 非 nil → 按 input_snapshot key 查非终态 run(终态列表与现两版逐字一致:existing_run 的判定),命中返回 existing;② 未命中/key nil → create(definition 归属/tenant/版本校验走既有 create action,authorize?: false,tenant: workspace_id)→ 紧接 start_run(同一函数体内,漏 start 不再可能);③ 失败原样上抛 |
| D4 | **speaker 事务红线**:speaker_invitation.ex:425 在 before_action prepare_create **同事务内**调用——统一入口必须保持纯顺序函数(不引入 after_transaction、不改变事务边界),该调用点行为逐字不变 |
| D5 | 留调用侧:research 的 link_research_run(190-210)与 ensure/fetch definition 链;learning 的 claim_in_handle 时序(PR-B 骨架);speaker 的 ensure_no_active_invitation 去重;三者的 instance_key 派生(research="event_<id>" / learning=enrollment_id / speaker 无) |
| D6 | 三 instantiator 的 find_or_create_run / existing_run / create_and_start_run 私有函数删除,改调统一入口;净删约 60-70 行(scout 实测),新增入口 ~40 行——**接受行数近持平**,价值在 invariant 不在删行 |
| D7 | 测试零改动:teaching_learning_test 幂等用例(428-451:重复→同 run,终态→新 run)、learning_flow、speaker_flow(input_snapshot["speaker_invitation_id"])全部原样通过即等价证据;入口本身不加新测试(纯收敛,既有测试覆盖三条路径) |

## 当前状态证据(scout QuerulousOwl)

- research:find_or_create_run(226-235)/instance_key(238-250)/existing_run(252-259)/create_and_start_run(262-285),state_based 幂等
- learning:同构四件套(191-243),claim_in_handle(claim 在 handle 体内 L79)
- speaker:start_run/3(31-53)两步在 42-52,无 run 级去重,before_action 事务内调用
- workflow_run.ex:无 find-by-key 查询;create/start/start_run 已有,入口只做编排
- 非终态去重两版逐字一致;input key 约定 input_snapshot["key"]

## 影响面

- **改**:workflow_run.ex(+入口 ~40 行)、research_instantiator.ex、learning_instantiator.ex、speaker_invitation_instantiator.ex(各删同构私有函数,改调入口)
- 测试/数据库/配置:零改动
- CONTEXT.md:不新增词条(instantiator 内部协议,非领域概念)

## 阶段与验收

1. WorkflowRun.find_or_create_and_start/4 + 契约内 moduledoc(key nil 语义、非终态列表、事务纯度)
2. research 迁移(link_research_run 留调用侧)→ teaching_learning_test 全绿
3. learning 迁移(claim 时序不动)→ learning_flow_test 全绿
4. speaker 迁移(事务语义逐字不变)→ speaker_flow_test 全绿
5. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
6. 验收:既有测试零改动全绿;grep 三 instantiator 无 find_or_create_run/existing_run/create_and_start_run 残留

## 风险与回滚

- speaker 事务内调用若引入隐式事务语义(如 start_run 内 after_transaction 与外层事务交互)——迁移前后 speaker_flow + 邀请失败回滚测试守护
- learning claim_in_handle:claim 在 handle 内、launch 在 instantiate 内,顺序敏感——只替换 create/start 编排,不碰 claim
- 回滚:单 PR revert

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → 常设规则合并

## 人类决策记录

- 2026-08-14 用户夜间授权自治流水线;D6 明确接受行数近持平(scout deletion test 结论:大收拢负收益,缩窄切口取 invariant 价值)
