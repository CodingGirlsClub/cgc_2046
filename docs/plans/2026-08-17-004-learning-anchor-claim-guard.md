# 架构深化候选 E+G：learning run↔enrollment 锚定单源（Enrollment.anchor）+ claim_in_handle 最小结构保证

> 日期：2026-08-17 · 来源：架构深化评审 2026-08-16 候选 E + G（`docs/reviews/architecture-review-2026-08-16.html`，git 2138b34；跟踪 issue #185）+ scout 只读取证（LearningAnchorScout，HEAD 098aa48 重定位）· 状态：自治流水线批准（用户 2026-08-17 点名「E+G」合并一个 PR）
> 范围纪律：行为不变——三消费者坍缩语义（SA→false / LPW→nil·:skipped / LI→warning+:ok）逐字保持；claim 键格式不变；现有测试零编辑全绿。G 降级为最小检测方案（方向② deferred）。

## 问题（HEAD 098aa48 坐实）

1. **E**：「learning run 锚定到哪条 Enrollment」概念在 Elixir 有三份私有拷贝，string/atom 双键处理不一致（SA 单 string 键 :143-146 / LPW·LI 双键）、错误原子三枚各自发明（`:error` / `:enrollment_not_found` / `:enrollment_read_failed`）：①`step_authorization.ex` fetch_enrollment L148-152（裸 :error，enrolled_learner? else→false）；②`learning_instantiator.ex` L141-147（双错误坍缩 :enrollment_not_found）+ input_enrollment_id L205-207 + instance_key L200-203；③`learning_progress_worker.ex` L210-222（:enrollment_read_failed，通配符坍缩 nil/:skipped）。
2. **G**：SignalSubscriber 骨架 `do_run` L77-79 将 `:claim_in_handle` 与 `:state_based` 合并直调 handle——「校验链后、副作用前调 claim」只是 moduledoc 纪律（L33-37），忘调则**静默退化**为 state_based。生产唯一使用者 = LearningInstantiator（claim 在 L86，位置正确）。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **`Cgc2046.Events.Enrollment` 侧新增锚定读取面**：`anchor/1`——入参 `map \| binary`（input_snapshot / 信号 payload / enrollment_id），先 `anchored_id/1` 双键提取（string 键优先，`Map.get(m,"enrollment_id") \|\| Map.get(m,:enrollment_id)`；binary 直通），无锚 → `{:error, :no_enrollment_anchor}`，有锚 fetch 失败 → `{:error, :enrollment_read_failed}`，成功 → `{:ok, %Enrollment{}}`。**放置面判定**：LI 在 fetch 点无 run struct（从信号 payload 出发），WorkflowRun 侧 API 只能服务 2/3 拷贝；Enrollment 侧零新增依赖（三拷贝已 alias）、依赖方向保持 Workflows→Events |
| D2 | **三拷贝变薄**：①SA `enrolled_learner?` 改调 `Enrollment.anchor(run.input_snapshot)`，错误→false（fail-closed 保持）；②LI instantiate with 链改 `Enrollment.anchor(data)`，错误→warning+:ok（best-effort 保持）；instance_key/input_enrollment_id 改调 `Enrollment.anchored_id/1`；③LPW fetch_enrollment_or_nil 改调 anchor，错误→nil、remind_stagnant→:skipped（坍缩语义逐字保持）。删除三份私有拷贝 |
| D3 | **错误原子统一**：`anchor/1` 双错误原子 `:no_enrollment_anchor` / `:enrollment_read_failed`（**避开** `:enrollment_not_found`——payments/order.ex 域错误同名原子 L512/645/682，语义不同域，防误读）。行为不变论证（scout 全库 grep）：三枚旧原子零测试钉死、零外部错误面消费，只活在日志插值与 with 通配符——统一仅日志文本变化，非行为契约 |
| D4 | **双键单点化取超集**：SA 单 string→双键。可达输入全为 string 键（input_snapshot 经 JSONB 持久化；唯一写入方 LI 以 string 键构造 input L87-91）——超集仅激活于不可达的 in-memory atom 键，零可达行为变更；对授权判定是安全方向（fail-closed 不放松） |
| D5 | **G = 方案 C（最小结构保证）**：`do_run` 的 claim_in_handle 分支在 `module.handle` 返回 `:ok` 后，经 consumer_key 派生键查 SignalIdempotency 行——缺失则 `Logger.error`（「claim_in_handle 订阅方返回 :ok 未 claim——静默 state_based 退化」）。~10 行，只触该分支，其余三策略与 6 订阅方零影响，现有测试零编辑全绿（现有 fixture 会 claim，不触发告警）。**方向②（before_claim/effects 双回调）deferred**：可行且已量化（只触 claim_in_handle 分支 + LI 重写 instantiate + ClaimInHandle fixture + 一个 describe），但生产用户仅 1，属投机结构化——第二个 claim_in_handle 用户出现时再做。**方向①（claim-once 闭包）否决**：动共享 @callback 契约且不保证时机。moduledoc L33-37 同步补「post-hoc 检测」说明 |
| D6 | **测试**：新增 `test/cgc_2046/events/enrollment_anchor_test.exs`（anchor/1 + anchored_id/1 纯函数 + 落库集成：存在/不存在/无锚/双键超集）；G 检测路径新增测试（fixture 忘调 claim → `Logger.error` 可断言，ExUnit capture_log）。**既有测试零编辑**（learning_flow / learning_progress_worker / step_authorization / signal_subscriber 全绿为行为不变证明） |
| D7 | **CONTEXT.md**：新增「learning 锚定（Enrollment Anchor）」词条（唯一真源 anchor/anchored_id + 三消费方 + 双键/双错误语义 + 边界不收清单）；SignalSubscriber 词条补 post-hoc 检测一句 |
| D8 | **不动**：reconciliation_scan_worker ×2（L200-207 批量收集 / L454 投影）、graphql ×2（L2136 SQL filter / L2255-2261 展示投影——顺带改 anchored_id 属美观，不做防范围蔓延）、ActorIsEnrolledLearner policy（委托非拷贝）、signal_subscriber 骨架其余三策略分支、claim 键格式 `enrollment.completed:<id>:learning_instantiator`、payments 域、ensure_confirmed 孤儿防护语义与顺序 |

## 改动清单

- **改**：`backend/lib/cgc_2046/events/enrollment.ex`（+anchor/1 +anchored_id/1）· `workflows/step_authorization.ex` · `workflows/learning_instantiator.ex`（fetch 改调 + 私有拷贝删）· `workers/learning_progress_worker.ex`（同）· `workflows/signal_subscriber.ex`（do_run claim_in_handle 分支 +post-hoc 检测 + moduledoc）· `CONTEXT.md`
- **新增**：`backend/test/cgc_2046/events/enrollment_anchor_test.exs`；G 检测路径测试（新增 fixture 或并入 signal_subscriber_test 新 describe——不改既有 describe）
- **不动**：D8 全清单 · 数据库/配置/前端/SDL：无

## 实施顺序与验收

1. Enrollment.anchor/anchored_id + 纯函数测试（先立安全网）
2. 三拷贝变薄（SA→LI→LPW，每步跑对应测试）
3. G 方案 C（post-hoc 检测 + moduledoc + 检测测试）
4. CONTEXT.md；两 commit 划分（E 先 G 后，bisect 安全）
5. 验收：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿；既有测试零编辑；grep 三份私有拷贝函数名零残留
