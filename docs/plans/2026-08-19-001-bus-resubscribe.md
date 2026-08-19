# Plan 2026-08-19-001 · 修复 #120：bus 重启后信号订阅方不重订阅

## 背景

`:cgc_workflow_bus`（Jido.Signal.Bus，permanent）的订阅表存在 bus 进程内存（`bus_state.ex`，无 journal）。bus 崩溃重启后订阅表清空，而订阅方 monitor 的是 forwarder 而非 bus（`jido_adapter.ex:701`）——forwarder 活着，无 DOWN、无重订阅、无日志。此后 `JidoAdapter.publish` 对空订阅返回 `:ok`，Oban job 已消费不重试：审批通知停发、workflow run 不实例化，**全程无报错**（`bus.ex:1027-1095` 空订阅静默成功）。

HEAD 上订阅方为 **8 个** GenServer（非 issue #120 点名的 2 个），全部经 `use Cgc2046.Workflows.SignalSubscriber` 骨架接入：NotificationSubscriber / SpeakerSubscriber / SponsorshipEndedSubscriber / EventCancelRefundWorker / LearningInstantiator / ResearchInstantiator / ResearchRunReaper / ShareSchemeInstantiator，共 15 条 pattern 订阅。生产侧唯一订阅入口是骨架（`signal_subscriber.ex:349`）——**修一处 = 修全部**。

## 决策

**路线 2：订阅方骨架 monitor bus + DOWN 后重订阅**（scout 2026-08-19 取证推荐）。

拒绝路线 1（supervisor `rest_for_one` + bus 前置）：bus 是 `Cgc2046.Supervisor` child #6（`application.ex:21`），其后 #7-20 含 StepHandlerRegistry、8 订阅方、AshAuthentication.Supervisor、Mcp.Server、Payments.ClientSup、Oban、Endpoint——`rest_for_one` 下每崩一次 bus 就连带重启 Endpoint（断服）与 Oban（job 扰动），blast radius 与故障不成比例。

## 实施单元（backend，单 PR）

### U1 骨架改造（`signal_subscriber.ex` + `jido_adapter.ex`）

1. **JidoAdapter 暴露 bus pid 解析**：新增 `whereis_bus/0`（内部 `Jido.Signal.Util.whereis(:cgc_workflow_bus)`）。一切 jido 调用经适配层（D-A1 适配层隔离），骨架不直调 jido_signal。
2. **骨架 init 时 monitor bus pid**（`signal_subscriber.ex:289-306` 区域）。bus 先于全部订阅方启动（child #6 vs #8-15），init 时 pid 可解析。
3. **handle_info({:DOWN, mref, :process, bus_pid, reason})**（新增分支，区别于既有 forwarder DOWN 分支 `:310-332`）：
   - demonitor 已有 bus ref（若需要）；
   - **回收旧 forwarder**：现骨架只存 `monitor_ref → pattern`，须补 forwarder pid 追踪，DOWN 时显式 kill 旧 forwarder（spawn 无 link，不杀则每次 bus 重启泄漏一条 receive 进程）；
   - 对全部 patterns 重订阅（复用 `subscribe_pattern/338-358`）；
   - **bus 未回归（`{:error, :not_found}`）不 `{:stop}`**：退避重试（固定间隔或指数退避，:timer 或 Process.send_after 自引用消息），防 crash-loop 与重订阅风暴。
4. **重订阅幂等**：bus DOWN 后旧订阅表已随进程消亡，重订阅即全新订阅；退避重试期间若 bus 回归，正常恢复。

### U2 测试（测试先行）

1. **真实重启场景**（区别于既有 4 处 terminate_child 用法——terminate_child 移除监督不自动重启，构不成「重启」）：
   - `GenServer.stop(:cgc_workflow_bus)` 或对 pid `Process.exit(:kill)` → permanent 策略自动重启 → 断言订阅恢复、信号投递恢复（如 fixture 订阅方收到 publish 的信号）。
2. **退避分支**：bus 重启窗口内重订阅遇 `:not_found` → 订阅方存活（不 stop）、退避后恢复。
3. **forwarder 回收**：bus 重启后旧 forwarder 不存活（计数或 monitor 断言）。
4. 既有 `signal_subscriber_test.exs:209-223`（forwarder 崩溃重订阅）零改动通过为回归证明。

## 验收标准

1. bus kill → 自动重启 → publish 信号 → 订阅方收到（8 个订阅方至少以骨架级 fixture + 1 个真实订阅方双证）。
2. bus 停止期间订阅方不 crash、退避重试、bus 回归后自动恢复订阅。
3. `mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿。

## 非目标

- **bus 重启窗口内已丢失的信号不可恢复**（无 journal，Oban job 已消费）——本 plan 修「重启后恢复订阅」，不修「窗口内不丢」。兜底仍是 SignalIdempotency claim + E-10 对账扫描。journal 引入另行决策。
- 不改 supervisor 树结构/策略（`application.ex` 不动或仅注释级说明）。
- 不动 8 个订阅方业务模块（修复全部收在骨架 + 适配层）。

## 风险

| 风险 | 缓解 |
|---|---|
| bus 反复崩溃 → 重订阅风暴 | 退避；退避上限后放弃并日志告警（订阅方保持存活，可观测） |
| init 时 bus 尚未注册（顺序理论保证但防御） | `:not_found` 走同一退避路径，不 stop |
| 旧 forwarder 泄漏 | U1.3 显式 pid 追踪 + kill |
| jido_signal 升级改订阅表结构 | 订阅经 JidoAdapter 适配层，升级只炸适配层（既有纪律） |

## 关联

- Issue #120（本 plan 关闭目标）
- Scout 报告：`agent://BusResubScout`（2026-08-19，HEAD 取证）
- 前史：PR #119 评审发现；2026-08-14 异步链路深化 PR-B 只覆盖 forwarder DOWN 重订阅，未覆盖 bus 重启（盲区由来）
