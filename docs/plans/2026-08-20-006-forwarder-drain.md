# Plan 2026-08-20-006 · 修复 #245：forwarder 回收 kill 截断在途投递（drain 协议）

## 根因（think 已批准设计，2026-08-20）

`signal_subscriber.ex:597-608` `reclaim_forwarders` 对旧 forwarder 直接 `Process.exit(pid, :kill)`。kill 落在「SignalIdempotency claim 已提交、effects 未执行」之间时：

- **claim_first / claim_in_handle**：claim 已烧、effects 未执行，未来重投被 `:duplicate` 拦截——幂等兜底与 E-10 对账对该形态失效（通知永久不发）；
- **claim_after_effects / state_based**：半执行可重复（副作用可能重复触发）。

关键机制事实：claim 与 effects 都在 forwarder 进程内**同步**执行（`do_run` 内联 claim→handle，含 rescue 归一化）；forwarder 在 `fun.()` 执行中收不到消息，邮箱里的消息只在 fun 跑完、循环回到 `receive` 时被处理。**「处理 drain 消息前」=「claim/effects 要么都完成要么都没开始」——截断窗口被消息语义天然关闭，无需锁。**

## 实施单元（backend，单 PR，2 lib + 2 test 文件）

### U1 `jido_adapter.ex` forward_loop 加 `:reclaim` 分支

forwarder receive 循环收到 `:reclaim` 后自退（`:ok`）。fun 执行中消息落邮箱等待——天然 drain 语义。

### U2 `jido_adapter.ex` 新增 `drain_forwarders/2`

spawn 一次性 waiter 进程：对每个传入 forwarder pid `Process.monitor(pid)` + `send(pid, :reclaim)`，receive 等全部 DOWN（带 deadline，默认 5000ms；超时者 `Process.exit(pid, :kill)` 兜底）。参数超时可注入（测试用）。放 adapter 层：forwarder 生命周期本归它管；waiter 持自己的 monitor，不扰动骨架状态机。

### U3 `signal_subscriber.ex` reclaim_forwarders 改 drain

`Process.exit(pid, :kill)` → `JidoAdapter.drain_forwarders(pids, timeout)`；demonitor + 清 state 逻辑不变。**bus DOWN 路径照旧立即退避重订阅**——drain 在旁路异步完成，不阻塞恢复。moduledoc 写明残余窗口（>timeout 卡死的 fun 仍被强杀截断，概率缩小非零）+ 点名前提「claim 与 effects 必须在 forwarder 进程内同步执行，若未来改异步则 drain 语义失效」。

### U4 测试（测试先行）

1. **截断闭合**：fixture handle sleep 300ms，publish 后 100ms kill bus → 断言 effects 恰一次落账（修复前此测试失败——effects 为零）。
2. **超时强杀**：fun 永久阻塞（receive 挂起）+ 注入 200ms 超时 → 断言 forwarder 被杀、waiter 退出、无泄漏。
3. **正常收工**：空闲 forwarder（无在途 fun）→ drain 快速返回。
4. 既有 #120 三测 + #244 探测两测零回归。

时序测试用宽余量（fun 300ms / 断言预算 2s）压 CI 慢机 flake 面。

## 验收标准

1. 上述 4 组测试全绿；`mix format --check-formatted` + `mix compile --warnings-as-errors`。
2. 全量 `MIX_ENV=test mix test --seed 1/2` 字面全绿（当前基线 1387，003-005 合并后按新基线）。
3. 截断闭合测试在修复前红、修复后绿（先红后绿取证）。

## 非目标

- claim+effects DB 事务化（effects 含 Oban 入队/telemetry，非 DB 原子，做不成）。
- forwarder 改 GenServer 用 `GenServer.stop(:normal, timeout)` 原生 drain（重写 forwarder，改动面大收益同）。
- bus 重启窗口内信号不丢（无 journal 既定非目标，同 #120）。
- E-10 对账扫描改动。

## 风险

| 风险 | 缓解 |
|---|---|
| 时序测试 CI 慢机 flake | 宽余量（fun 300ms/预算 2s）；断言终态非中间态 |
| waiter 自身泄漏（forwarder 永不死） | 超时强杀 + waiter receive 带 overall deadline 必退 |
| 前提失效（未来 effects 异步化） | moduledoc 点名前提；drain 语义降级为旧 kill 行为（不劣化现状） |
| 并行 003-005 线 rebase 交错 | 本线只动 signal_subscriber/jido_adapter + 对应测试，与三线文件零重叠；合并时后到者 rebase |

## 关联

- Issue #245（关闭目标）；#243（前史 A2）/ plan 2026-08-19-001（授权显式 kill 的原始决策）
- think 批准记录：本会话 2026-08-20（推荐版三处改动）
