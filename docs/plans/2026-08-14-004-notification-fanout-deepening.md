# 通知分发面深化：NotificationFanout

> 日期：2026-08-14 · 来源：架构评审（report 1786689868）候选① + grilling 两轮定稿 · 状态：已批准（决策全采纳）
> 前置：**异步链路 PR-B（SignalSubscriber 骨架）合入后开工**（PR-C）。
> 范围纪律：只动收件人解析 + 通知入队面；SignalSubscriber 骨架与 claim 幂等、NotificationService 发送侧、NotificationWorker、`target_title`/`event_title` 的 Event/Course 分叉（属 offering seam 候选④）一律不碰。

## 目标

统一 `Cgc2046.NotificationFanout`——三份 `managed_identities_by_user` / 两份 `identities_for_user` / 两份 `insert_notification` 同构拷贝收敛为一个 deep module；删除 NotificationSubscriber 的公共入队面（异步计划 Q4 backlog），使其退化为纯订阅方。

## 锁定决策（grilling 定稿）

| # | 决策 |
|---|---|
| Q1 | 新建 root 单文件 `lib/cgc_2046/notification_fanout.ex`，不设目录、不并 NotificationService（入队 + 发送两段管道不同 module） |
| Q2 | 两段式 interface：resolution（可预取缓存）+ deliver（逐组入队）；不加便利层（YAGNI） |
| Q3 | 收件人选择器数据化：`:manage`（内部走 `Role.manage_roles/0` 唯一真源）｜`{:roles, [...]}` 显式窄集 |
| Q4 | 单用户路径并入 scope；`identities_for_user` ×2、`insert_notification` ×2 一并收敛 |
| Q5 | 删 NotificationSubscriber 全部 5 个公共 enqueue 函数；ARW / LPW / 测试直调 fanout |
| Q6 | 错误内化：rescue 不崩、必 Logger + telemetry；静默跳过语义保持不变（纯收敛，不改行为） |
| Q7 | 时序：PR-B 合入后作为独立 PR-C（本候选改 handle 体、PR-B 改 handle 外壳，顺序做互不踩、免双迁移） |
| Q8 | 形状：`managers/2` → `%{user_id => [identity]}`；`identities/1` → `[identity]`；`deliver(recipients, template_key, data, job_meta, unique)` 的 recipients 归一接受 map 或 `{user_id, [identity]}` |
| Q9 | unique 命名预设 `:default`｜`:reminder_7d`（现 NS 私有 `@reminder_unique` 收进 fanout 成唯一真源）；deliver 默认 `:default` |
| Q10 | telemetry `[:cgc2046, :notification_fanout, :deliver]`，measurements `%{count: n}`，metadata `%{status, template_key, error}` |
| Q11 | 测试面：fanout 单测新增；`notification_service_test.exs` 直调点迁移；订阅方 flow 测试 / `async_signal_test` / worker 测试**不动**（行为断言 = 迁移正确性证据） |
| Q12 | CONTEXT.md 词条「通知分发面（Notification Fanout）」（已随本 plan 落盘 §8） |

## 当前状态证据（2026-08-14 静态探查）

- 三份 `managed_identities_by_user`：notification_subscriber.ex:346 / speaker_subscriber.ex:184 / approval_reminder_worker.ex:214，源码注释互认「同款实现」
- 谓词两拼法：订阅方走 `Role.manage_role?/1`、ARW 走字面量 `[:owner, :admin]`——今天等价（`@manage_roles = [:owner, :admin]`），潜在分叉：`@manage_roles` 变更时 worker 不跟随
- `identities_for_user` ×2（NS:185 / SS:176）；`insert_notification` ×2（NS:193 带 unique_override、SS:210 无）
- NS 兼职公共入队面 3 个外部调用方：ARW ×2（approval_reminder_worker.ex:102,137）、LPW ×1（learning_progress_worker.ex:144）；测试直调 2 处（notification_service_test.exs:92,99,121）
- ARW 按 workspace **预取一次**分组、逐条 enrollment 复用（消 N+1）——interface 必须两段式的决定性事实
- LPW 的 `:no_identity → :skipped` 是调用方分类语义，迁移后留在 LPW（`identities/1` 返回 `[]` 时自行分类）

## 影响面

- **新建**：`lib/cgc_2046/notification_fanout.ex` + `test/cgc_2046/notification_fanout_test.exs`
- **改**：
  - notification_subscriber.ex——删 5 公共 enqueue 函数 + 3 私有助手（identities_for_user / insert_notification / managed_identities_by_user），handle 体与 `enqueue_approval_result` 内部路径改调 fanout
  - speaker_subscriber.ex——删 3 私有助手，notify_workspace_managers / notify_speaker 改调 fanout
  - approval_reminder_worker.ex——删 2 私有助手（managed_member_ids / managed_identities_by_user），两处扫描改调 `fanout.managers(ws_id, selector)`
  - learning_progress_worker.ex——改调 `fanout.identities/1` + `deliver/5`，`:skipped` 分类留原地
  - notification_service_test.exs——2 处直调点改调 fanout
- **文档**：CONTEXT.md §8 新词条（已落）
- **数据库 / 配置**：无

## 阶段与验收

1. `NotificationFanout` module + 单测：选择器语义（`:manage` 走 `@manage_roles`、`{:roles, [:owner]}` 窄集）、分组形状、空集、deliver args 形状（identity_uid / platform / template_key / data / job_meta 合并）、unique 预设映射、rescue 不崩 + telemetry 计数
2. NS 迁移（handle 体 + 删公共面）→ 既有 NS 相关测试绿
3. SS / ARW / LPW 迁移 → 各 flow / worker 测试绿（断言不改）
4. 全量 `mix test` ×2 seeds + format + `compile --warnings-as-errors`
5. 验收：既有信号流 / worker 测试全绿且断言未改（行为不变）；NS 无公共入队残留；telemetry 事件可观测

## 风险与回滚

- 行为漂移风险：rescue 语义 / args 形状逐点对照既有测试；unique 预设 ↔ Oban unique 映射加 pin 测试
- 回滚：单 PR revert 即可；无数据迁移，无部署依赖

## signoff 标准

- advisor01 check 评审 PASS（hard stops 0）
- 全量测试绿 + format/compile 干净
- 前置确认：PR-B 已合入 develop

## 人类决策记录

- 2026-08-14 用户选定候选①；grilling 两轮全按推荐（「全部采纳」×2）
