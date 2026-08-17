# 架构深化候选 D：通知类型契约 registry 化（NotificationWorker 表驱动 + 契约单点）

> 日期：2026-08-18 · 来源：架构深化评审 2026-08-16 候选 D（`docs/reviews/architecture-review-2026-08-16.html`，git 2138b34；跟踪 issue #185，最后一个候选）+ scout 只读取证（NotificationRegistryScout，HEAD 2ca9d57 重定位）· 状态：自治流水线批准（用户 2026-08-18 点名「D」）
> 范围纪律：行为不变——stale 语义逐类型不变（谓词接 `not_expired?/2`，评审原文「接 overdue?」已被候选 B 的放行谓词取代）、unique 窗口逐类型不变、Oban args 形状不变（`[:worker, :args]` unique 依赖精确形状）。

## 问题（HEAD 2ca9d57 坐实）

「通知类型」概念无载体：10 个 template_key × 6 生产文件的契约（data 键集 / job_meta 键集 / unique 预设 / stale 重查）散在 生产方构建点 × Worker 子句 × config × 各 moduledoc 四处：

1. **NotificationWorker 解释器反模式**（notification_worker.ex:57-99）：`stale_reminder?/1` 三条手写子句按 template_key×data 键分派（approval_reminder×enrollment_id / ×sponsorship_id / learning_stagnation×run_id）；删一条子句静默发过期提醒，无编译/测试信号。
2. **unique 预设传参散落**：ARW:103/:151 与 LPW:190 手传 `:reminder_7d`——真源在 Fanout `@reminder_unique`，但「哪些类型用哪个预设」无声明处。
3. **跨面漂移已实证**：miniprogram `SubscriptionScenario` 含 `event_reminder`（domain/models.ts:17），后端 config 无此键——`grantConsent('event_reminder')` 返回 `:template_not_configured`。单一类型宇宙的缺位证据。

## 锁定决策

| # | 决策 |
|---|---|
| D1 | **registry 形状 = AEW @expiry_specs 先例**（Worker 持有模块属性表 + 单解释器）：`NotificationWorker` 内 `@notification_types`，公开 `type/1`（返回条目 \| nil）供生产方/Fanout/测试读契约。条目字段：`template_key / id_key（stale 分派键）/ data_keys / job_meta_keys / unique 预设 / stale`。**stale 三元组** `{resource, required_status, :not_expired \| :running}`（nil = 不重查）：deadline 类一律 `ApprovalDeadline.not_expired?/2`（放行谓词；**禁用 overdue?/2**——不对称对偶，==now 与 nil 侧行为翻转）；running 类 = WorkflowRun `status == :running`。非 pending/非 running/读失败 → stale=true（跳过，现行为保持） |
| D2 | **Worker 解释器化**：`stale_reminder?/1` 三子句删除，改 1 个查表解释器（type/1 → stale 元组 → 统一判定）；未知类型/nil stale → false（不重查，现兜底保持）。删行 → 静默不重查由 D7 契约测试抓 |
| D3 | **unique 预设收敛**：Fanout.deliver 的 unique 参数改可选（缺省按 template_key 查 `NotificationWorker.type/1` 的表），显式传参仍兼容；ARW:103/:151 与 LPW:190 删 `:reminder_7d` 传参（改查表）。**Fanout.deliver 签名与 args 形状不变**（位置参数 + `[:worker, :args]` unique 依赖的精确形状） |
| D4 | **payload 值构建不收敛**（对评审「payload builder」条目的诚实收窄）：10 个类型无共享形状，值构建上下文各异（signal payload / 扫描记录 / Order）——留生产方手拼（AEW 先例同款「规格数据化、动作留代码」）。收敛面 = 键集契约 + unique + stale 谓词 |
| D5 | **不收边界**（deletion test 判定）：NotificationFanout 主体（真深模块——managers/identities/deliver/@reminder_unique/错误内化+telemetry；F 仅新增 {:roles,_} 消费者坐实选择器是数据）· NotificationService（template_id 映射 + consent 原子消费）· Miniprogram.Client（平台信封）· config 面与 miniprogram SubscriptionScenario（独立数据面，只加 D7 双射测试锚定，不做跨面收敛）。**event_reminder 漂移处置**：仅记录为 advisory（前端删键或后端补键是产品决策，不塞本 PR） |
| D6 | **生产方接线不变**：subscriber/worker 仍自构建 data/job_meta 值；moduledoc 契约描述改引用 `NotificationWorker.type/1`（生产方注释里散落的键集文档删，单点化） |
| D7 | **测试**：新增 `test/cgc_2046/workers/notification_worker_test.exs`（表驱动契约：① config :miniprogram_templates 键集 ↔ @notification_types 双射；② 每条目 stale 语义——approval_reminder×2 {pending+future→投递, expired→跳过+consent 不消耗, 非pending→跳过}、learning_stagnation {running→投递, 终态→跳过}、非提醒类型→不重查）。既有测试零编辑全绿（fanout/service/ARW/learning_flow/speaker_flow/refund/settlement 钉死面是行为护栏） |
| D8 | **文档**：CONTEXT.md 新增「通知类型（Notification Types）」词条（registry 唯一真源 type/1 + 字段语义 + 收敛/不收边界 + config 双射锚）；Fanout 词条 unique 段补「缺省查表」一句 |

## 改动清单

- **改**：`backend/lib/cgc_2046/workers/notification_worker.ex`（@notification_types + type/1 + 解释器 + moduledoc）· `backend/lib/cgc_2046/notification_fanout.ex`（unique 缺省查表，签名兼容）· `workers/approval_reminder_worker.ex` + `workers/learning_progress_worker.ex`（删 :reminder_7d 传参）· `CONTEXT.md`
- **新增**：`backend/test/cgc_2046/workers/notification_worker_test.exs`
- **不动**：D5 全清单 · notification_subscriber/speaker_subscriber/payment_* 生产方构建点（D6）· 数据库/前端/SDL：无

## 实施顺序与验收

1. @notification_types 表 + type/1 + 表驱动测试（先立安全网，含 config 双射）
2. Worker 解释器替换三子句（stale 语义逐类型等价）
3. Fanout unique 缺省查表 + 三处传参删除
4. CONTEXT.md + 生产方 moduledoc 键集文档单点化
5. 验收：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿；既有测试零编辑；grep `:reminder_7d` 仅剩 Fanout @reminder_unique 与 registry 表
