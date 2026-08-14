# Offering 读取面 seam:Events.Offering 统一 Event/Course 分叉重解

> 日期:2026-08-15 · 来源:架构评审(report 1786689868)候选④ + scout 静态探查(CloudyHaddock,HEAD 5d97bac)· 状态:自治流水线批准
> 范围纪律:**只收读取面**;lifecycle change 不收(信号名 event.*/course.* 必须保持不同——subscribers/tests/outbox 全依赖,可共享面只剩 CAS 辅助 ~50-70 行,证据不足);enrollment SQL kind-dispatch 家族机制不同(裸 SQL)不收;ADR-0002 分资源决策不碰。

## 目标

`Cgc2046.Events.Offering` deep module 拥有「一行可指向 Event 或 Course」的读取面:五处各自为政的 Ash.get 分叉收敛为一个 interface,错误形状 3 种坍缩为 `{:error, :not_found}` 单点。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | 模块 `Cgc2046.Events.Offering`(events/ 目录,读取面 seam);**返回完整 entity + kind**,不做纯投影返回值(research_instantiator 需 status/research_enabled,graphql 需完整 struct 供 Readiness) |
| D2 | interface:`fetch(kind, id, opts \\ [])` → `{:ok, entity} \| {:error, :not_found}`;kind 为 `:event \| :course`;opts:`authorize?: false`(默认,匹配现④⑤处分叉行为)/`actor:`(graphql 场景,全库唯一 actor 感知读取)/`tenant:`(批量场景)。便利投影:`kind/1`、`title/1`、`workspace_id/1`(entity → 值) |
| D3 | `fetch_by_signal_payload(data)` → `{:ok, entity} \| {:error, :not_found}`:按 payload 键 event_id/course_id 分派(消灭各处手写键探测);`fetch_titles_by_ids(ids_by_kind, tenant)` 批量(供 PendingApprovals load_offering_titles,保持 tenant 作用域 Ash.read 批量形状,消 N+1 不退化) |
| D4 | 五处迁移:①NS target_title/1(错误 :event_not_found/:course_not_found/:target_not_found 坍缩 :not_found,仅用于日志,无测试断言)②LI fetch_entity + entity_title ③PA load_offering_titles + context_title ④GQL fetch_offering_by_id(actor: 感知)⑤RI fetch_entity(kind 原子版) |
| D5 | 不动:enrollment.ex SQL 家族(exactly_one_target/target_from_record/target_table/target_column/claim_cancellable)、event_lifecycle_worker(已泛化)、research_run_reaper(只拼 key 无读取)、sponsorship level :event 原子(与 offering kind 撞名但无语义关系,Offering moduledoc 注明命名空间) |
| D6 | 错误坍缩审计:①的三种错误只进日志无消费方;②已统一 :entity_not_found;③④⑤各自错误分支迁移后统一 :not_found——grep 证明旧错误原子零残留消费方后方可坍缩;有消费方的保留映射 |
| D7 | 测试:既有全部测试零改动(行为保持;course 分支①②③本就无直接测试,不补行为测试);Offering 模块单测新增:fetch 两种 kind/两边都没有→:not_found/actor 与 authorize 选项/fetch_by_signal_payload 键分派/批量形状 |

## 当前状态证据(scout CloudyHaddock)

- 归一后 109 行差异:Event 独有 sponsorship 三字段 ~30 行 + 信号串/表名/payload 键/GraphQL 名/slug 前缀等机械差异;lifecycle CAS 块逐字同构但受信号名红线挡
- 五分叉:NS 130-143 / LI 155-172 / PA 238-271(批量)/ GQL 1785-1790(actor 感知,全库唯一)/ RI 166-177(kind 原子,handle 70-76 从 payload 键解析)
- 测试面:event 路径全覆盖,course 分支①②③无直接测试——零改动即证据
- deletion test:净删 ~40-60 行,复杂度集中(分叉从 N 处变 1 处 switch)

## 影响面

- **新建**:lib/cgc_2046/events/offering.ex + test/cgc_2046/events/offering_test.exs
- **改**:notification_subscriber.ex、workflows/learning_instantiator.ex、events/pending_approvals.ex、graphql_schema.ex(fetch_offering 调用点)、workflows/research_instantiator.ex
- 测试/数据库/配置:零改动(除新增 Offering 单测)
- CONTEXT.md:增词条「Offering(供给物读取面)」——{kind,id} → entity 的分派单点,注明与 sponsorship level :event 的命名空间区分

## 阶段与验收

1. Offering module + 单测(五接口面 + not_found + 选项)
2. 逐处迁移(①→②→③→④→⑤),每处迁移后对应 flow 测试绿
3. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
4. 验收:既有测试零改动全绿;grep 五处旧分叉函数零残留;D6 错误原子坍缩审计完成

## 风险与回滚

- GQL actor 感知读取走 Offerin g 后若默认 authorize?: false 会绕过策略——D2 opts 显式,fetch_offering 调用点必须传 actor
- PA 批量若误改单读会 N+1——fetch_titles_by_ids 保持批量形状,单测守护
- 回滚:单 PR revert

## signoff 标准

- advisor01 check PASS + hard stops 0 + advisory 无必修 → 常设规则合并

## 人类决策记录

- 2026-08-15 用户夜间授权自治流水线;scout 建议只收读取面,lifecycle 与 SQL 家族不收,依证据采纳
