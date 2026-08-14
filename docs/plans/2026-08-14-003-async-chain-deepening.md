# 异步链路深化：SignalEmitter + SignalSubscriber

> 日期：2026-08-14 · 来源：架构评审（report 1786680553）+ grilling 两轮定稿 · 状态：已批准
> 范围纪律：只动信号发布/消费形状；ADR-0002 依赖方向、SignalPublishWorker、SignalIdempotency 表结构、SignalLog（入向审计）、形状 C（speaker 直调引擎）一律不碰。

## 目标

1. **PR-A（③ 生产者面）**：统一 `Cgc2046.Events.SignalEmitter`——四种发布形状归一为「after_action change + 事务内 Oban outbox」，幂等键与 payload 规范上收。
2. **PR-B（①+② 消费者面）**：统一 `Cgc2046.Workflows.SignalSubscriber`——六订阅方骨架收拢（behaviour + use 宏），JidoAdapter 总线 interface 收口（删 subscribe/3 连坐变体、删 partition 死参数、struct 解包），订阅生命周期 fail-fast + DOWN 重订阅共享，公开 `deliver/2` 同步测试入口。

## 锁定决策（grilling 定稿）

| # | 决策 |
|---|---|
| Q1 | ① = behaviour + `use` 注入骨架（编译期回调检查） |
| Q2 | `idempotency: :claim_first \| :claim_after_effects \| :state_based` 三枚举如实保留现状语义 |
| Q3 | 订阅失败 `subscribe!` 即崩，监督树重试 + telemetry |
| Q4 | NotificationSubscriber 兼职提醒入队面留原地（记 backlog） |
| Q5 | ③ = Ash after_action change 模块形态 |
| Q6 | 7 种 fire-and-forget 信号升级为事务性 outbox（enrollment.* / sponsorship.* / *.launched） |
| Q7 | 形状 C 不拆（backlog） |
| Q8 | 分 PR，③先行 |
| Q9 | 六订阅方一次全迁，无并存态 |
| Q10 | 回调 `handle(signal_type, data) :: :ok \| {:error, term}`，函数子句分流 |
| Q11 | claim_after 仅 `:ok` 时落；`{:error}` 只 Logger+telemetry 不 crash forwarder；语义事实只在骨架 moduledoc |
| Q12 | 生产者键 `"<type>:<record_id>"` 由 emitter 注入 payload；消费者 claim 键 = `payload键 <> ":" <> consumer短名`；资源不再自拼键 |
| Q13 | payload fn 签名 `fn changeset, result -> map` |
| Q14 | 形状 B（event.ended/course.ended/speaker.*）一并迁入 emitter |
| D1 | 删 subscribe/3；subscribe_detached→subscribe；删 partition 参数；adapter 内解包 struct |
| D2 | 骨架在 workflows/signal_subscriber.ex；六订阅方模块名/位置不动 |
| D3 | LI 的 DOWN 重订阅上收进骨架，六方共享 |

## 当前状态证据（scout 2026-08-14 静态探查）

- 骨架同构：6 订阅方 1490 行中 ~270 行同构（init 订阅循环五份逐字相同）
- claim 三分裂：claim-first×3（NS/SS/LI）、claim-after×2（SES/RRR）、无 claim×1（RI）；SES/RRR 注释错引 publish 重试为重投来源
- adapter：forward_loop 11 行配 7 条隐含须知；5/6 调用方仍用 spawn_link 连坐变体
- 生产者：四种形状并存 ~370 行；`enrollment.completed`（最重信号）拿最弱 fire-and-forget 保证
- 测试搏斗：async_signal_test.exs:42 terminate 应用进程避竞争；5/6 订阅方测试直调 handler

## 被否方案

- 纯 `use` 宏参数化（缺编译期回调检查）· 运行时分发注册表（过度）
- claim 时机统一成一种（重构改语义，禁）
- ③ 用钩子函数而非 change 模块（发布藏进函数体，可读性差）
- 试点迁移（引入两种骨架并存的中间态）
- delivery 即 Oban job（Speculative，待信号量级验证，backlog）

## 影响面

- **PR-A**：新建 `events/signal_emitter.ex`；改 enrollment.ex / sponsorship.ex / event.ex / course.ex / speaker_invitation.ex 的信号发布钩子（~370 行收敛）；相关测试更新（拦截 publish 的测试改拦 job 入队或 emitter）
- **PR-B**：新建 `workflows/signal_subscriber.ex`；改 jido_adapter.ex 总线段 + 六订阅方 + application.ex（无需改）+ async_signal_test 等测试面改经 `deliver/2`
- 数据库：无迁移。SignalIdempotency 表结构不变；存量 claim 键格式不换
- 配置：无

## 阶段与验收

### Phase A（PR-A）
1. `SignalEmitter` change 模块 + 单测（幂等键派生 / payload fn 调用 / after_action 事务内入队）
2. 逐资源迁移发布钩子（enrollment → sponsorship → event/course → speaker），每资源迁移后跑对应既有测试
3. 全量 `mix test` + format + compile --warnings-as-errors
4. 验收：既有信号流测试全绿（行为不变）；emitter 单测覆盖新契约；信号仍到达（async_signal_test 绿）

### Phase B（PR-B，依赖 PR-A 合入）
1. JidoAdapter 收口（删 subscribe/3、rename、删 partition、解包 struct）+ adapter 层测试
2. `SignalSubscriber` 骨架 + behaviour + 骨架单测（三策略 claim 时机 / deliver 入口 / subscribe! 失败路径）
3. 六订阅方一次全迁（模块名/位置不动）+ 各 flow 测试改经 `deliver/2`
4. async_signal_test 移除 terminate 应用进程搏斗（若可行）
5. 全量 `mix test` ×2 seeds + format + warnings 检查
6. 验收：六方行为不变（既有测试绿）；骨架单测覆盖新契约；adapter 无 subscribe/3 残留调用

## 风险与回滚

- 语义漂移风险：claim 三枚举如实映射现状为防线；迁移后逐方对照既有测试
- 测试拦截点漂移：PR-A 中凡测试直拦 `JidoAdapter.publish` 的，改拦 Oban job 入队断言
- 回滚：两 PR 独立，revert 即可；无数据迁移，无部署依赖

## signoff 标准

- 两 PR 各自 advisor01 check 评审 PASS（hard stops 0）
- 全量测试绿 + format/compile 干净
- PR-B 合入后 #134 收编项①（订阅方冒烟测试）具备落地条件（deliver/2 存在）

## 人类决策记录

- 2026-08-14 用户选定候选 ①+③；grilling 两轮全按推荐；本 plan 经用户「ok」批准
- 2026-08-14 PR-B 评审修正（codex P1）：claim 枚举增补第四值 `:claim_in_handle`
  （LI 专用）——claim 回到 LI 旧时序「校验链通过后、launch 前」，避免烧掉
  「无已发布学习定义 / 瞬时读失败」场景的重投资格；骨架提供 `claim/3` 助手，
  消费键派生仍归骨架唯一持有。Q2 的「如实映射现状语义」以此为准。
