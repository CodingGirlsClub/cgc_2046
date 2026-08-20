# Plan 2026-08-20-002 · 修复 #244：signal subscriber give-up 终端态 + smoke 第 8 方

## 根因现状（scout 2026-08-20 取证，HEAD 139e897）

**A1 · give-up 是终端态**：`signal_subscriber.ex:556-564` 退避 30 次（≈126s）后 give-up 分支直接返回 state——不再 `send_after`、`bus_monitor` 已 nil、forwarders 已回收。唯一恢复入口是杂散 `:bus_resubscribe` 消息（生产者从不发）。单次 >2min outage（部署间隙/bus init 阻塞）后 bus 健康回归也永久失聪，可观测性只有一条一次性 error 日志。

**A10 · smoke 缺第 8 方**：`signal_subscriber_smoke_test.exs:16-24` 只有 7 方（缺 `Cgc2046.Workers.EventCancelRefundWorker`）；test 名（:27）与 moduledoc（:5）也写「七」。`application.ex` 实际 8 订阅方，无新增。

**A7 复核结论**：多退避链共享计数器经 M1+A4 修复后主路径已消解，残留窄竞态有界——不单独修。

## 实施单元（backend，单 PR）

### U1 give-up 转低频无限探测（治 A1）

`signal_subscriber.ex` give-up 分支（:556-564）改为：到达 max_retries 后**不放弃**，转入低频探测模式——`Process.send_after(self(), :bus_resubscribe, @probe_interval)`（30s 常量，与退避常量同处 :309-311 区域）。

- 复用既有 `:bus_resubscribe` guard 分支（:406-432）：`whereis_bus` 探测无副作用；bus 回归 → `full_resubscribe` → 成功路径已现成复位（`bus_monitor` 重建 + `bus_retries` 归 0，:464-466）→ 自动回到正常态。
- 探测模式下 `bus_retries` 保持 max 不再递增（防日志/事件刷屏）；error 日志保持一条。
- 给 guard 分支加探测态处理时注意：探测消息与正常退避消息同型（`:bus_resubscribe`），靠 `bus_retries == max` 区分或加独立 state 字段——writer 按 think 定，保持最小。

### U2 telemetry 一次性事件（可观测性）

- `[:cgc2046, :signal_subscriber, :give_up]`：进入探测模式时发一次（measurements `%{retries: max}`，metadata subscriber 名）。
- `[:cgc2046, :signal_subscriber, :recovered]`：探测成功恢复时发一次（metadata 含 was_probe: true 或等价）。
- 事件 emit 对齐骨架既有 telemetry 惯例（:95 声明 / :203-217 emit 形状）；测试对齐 `notification_fanout_test.exs:299-314`（attach_many + unique handler_id + on_exit detach）。

### U3 退避参数 use 可注入（可测性，默认不变）

`use Cgc2046.Workflows.SignalSubscriber` 增加可选 opts：`max_retries` / `probe_interval`（默认现值 30 / 30s）——测试 fixture（`bus_restart.ex` 或新 fixture）传毫秒级小值，使 give-up→探测→恢复全链可在秒级测试。

### U4 smoke 补第 8 方

`signal_subscriber_smoke_test.exs`：`@subscribers` 列表加 `Cgc2046.Workers.EventCancelRefundWorker`；test 名与 moduledoc「七」→「八」。断言结构零改动。

## 测试（测试先行）

1. **give-up→探测→恢复**（注入小参数）：bus 消失 → 退避耗尽 give-up → telemetry `:give_up` 恰一次 → bus 回归（restart_child）→ 探测期内自动恢复 → telemetry `:recovered` 恰一次 → 投递恢复断言。
2. **探测不刷屏**：探测多次往返 bus 仍缺，`bus_retries` 不再递增 / 无重复 give_up 事件。
3. **smoke 8 方**全绿。
4. 既有 #120 三测 + 全套件零回归。

## 验收标准

1. 上述测试全绿；`mix format --check-formatted` + `mix compile --warnings-as-errors`。
2. 全量 `MIX_ENV=test mix test --seed 1/2` 字面全绿（基线已达成，不得回退）。
3. 生产语义：订阅方永不永久失聪（>2min outage 后 30s 内自动恢复）；探测风暴不可能（30s 固定间隔 + 无重入）。

## 非目标

- A7 残留窄竞态（有界，不修）。
- #245 drain 协议（独立线）。
- 退避参数配置化到应用环境（use 注入仅测试用，默认硬编码不变，YAGNI）。

## 风险

| 风险 | 缓解 |
|---|---|
| 探测消息与正常退避同型导致语义混淆 | U1 writer think 时明确区分策略；测试覆盖两态 |
| probe_interval 常量写错单位 | 与退避常量同处定义 + 单位后缀命名 |
| telemetry 事件名与既有 namespace 冲突 | scout 已核实骨架现有事件位置，扩展同族 |

## 关联

- Issue #244（关闭目标）；#243（前史）/ #248（flaky 收口后全量全绿基线）
- Scout：`agent://SignalFollowupScout`
