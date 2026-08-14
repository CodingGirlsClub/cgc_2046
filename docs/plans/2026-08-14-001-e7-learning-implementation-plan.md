# E-7 #122 学习 workflow 协议落地——实施计划

> 日期：2026-08-14 ｜ 作者：sole-writer（E-7）｜ 状态：已签核设计的实施计划（think 产物）
> 权威设计：`docs/01-定稿设计/学习workflow详细设计.md`（v1.0 定稿，D6 三决策签核）
> 上游规格：`docs/plans/2026-08-13-001-slice-e-integration-plan.md`（E-7 规格段）
> 分支：`feat/learning-workflow`（worktree `../cgc_2046-learning`，base `origin/develop`）

## 1. 范围与非范围

**范围（验收四条）**

1. `LearningInstantiator`：订阅 `enrollment.completed`，幂等种 learning run，注册进监督树。
2. 授权账本接线：`update_facts_for_mcp` policy 加「报名学员本人可写自己 learning run」分支；`save_step_output` 载荷加可选 `reason` 字段（D6-① variance）。
3. 完成判定：`LearningProgressWorker`（Oban cron）扫 `type=learning` 且 `running` 的 run，末个 manual step 的 `facts[step_key]` 已存在 → 调 `:complete` 置 `succeeded`（D6-②）。
4. 停滞升级：`running` 且 facts 无新增 > 7 天 → 经 NotificationWorker 入队提醒报名学员（D6-③）；不自动 cancel。

**非范围**

- 不编排执行、不发新信号、不新增写工具；不动 Enrollment/Sponsorship/SpeakerInvitation 代码。
- 答疑分支（设计 §7，🟡 待 v1）；报名取消联动 `enrollment.cancelled`（E-2 订阅方范围）。
- 对账扫描本体（E-10）；本切片只保证检测信号可观测（warning 日志 + run 状态可扫）。
- 小程序停滞提醒模板 ID 的生产注册（设计 §4.4：运营配置，上线时登记）。
- 无新 Ash 资源、无新依赖、无 migration。

## 2. 现状调研结论（实施前提，均已读源码确认）

| 接缝 | 现状 | 出处 |
|---|---|---|
| 实例化蓝图 | `ResearchInstantiator`：GenServer + `JidoAdapter.subscribe` + `launch/4` 同步公开 API + `find_or_create_run`（非终态幂等） | `research_instantiator.ex` |
| 幂等键 | `SignalIdempotency.claim/3`，Postgres 唯一索引 `(signal_type, idempotency_key)` | `signal_idempotency.ex` |
| **幂等键冲突** | `NotificationSubscriber` 已 claim 裸键 `"enrollment.completed:<id>"`（生产者 payload 携带）；同键再 claim 会互撞 | `notification_subscriber.ex:225` |
| 消费者作用域先例 | `SponsorshipEndedSubscriber` claim `"event.ended:event_<id>:sponsorship_ended"`；`ResearchRunReaper` claim `"<type>:<key>:research_run_reaper"` | 各自模块 |
| 工具层门控 | `Wrapper.run` → `check_membership`：**非成员在入口即被拒**（仅 confirm/cancel 豁免） | `wrapper.ex:60-69` |
| Ash policy | `update_facts_for_mcp` bypass 仅成员/平台管理员；非成员落到 OwnerOrAdmin policy → Forbidden | `workflow_run.ex:517-520` |
| StepRole 判定 | `StepAuthorization.authorize_signal/4`：owner/admin 豁免；未配置 StepRole = 不限制；读失败 fail-closed | `step_authorization.ex` |
| 写路径 | `save_step_output`：`output` 浅合并进 `facts[step_key]`；终态拒绝 | `save_step_output.ex` |
| 完成动作 | `update :complete`（running/waiting → succeeded，乐观锁，状态守卫幂等） | `workflow_run.ex` |
| cron 先例 | `ApprovalExpiryWorker`：`*/5 * * * *` cron + `unique: [period: 300]` + 单记录失败不中断整拍 | `approval_expiry_worker.ex`、`config.exs` |
| 48h 提醒先例 | `ApprovalReminderWorker` 扫描 → `NotificationSubscriber.enqueue_*_reminder_jobs`（按 UserIdentity 逐身份入队）→ `NotificationWorker`（7 天 args-unique 去重 + 发送时 stale 重查） | `approval_reminder_worker.ex`、`notification_subscriber.ex`、`notification_worker.ex` |
| 定义枚举 | `WorkflowDefinition.type` 已含 `:learning`（领域模型 ER 权威源） | `workflow_definition.ex:42` |
| node_def 契约 | `%{"steps" => [%{"id" => key, "type" => "manual" \| ...}]}`，数组顺序即拓扑序 | `jido_adapter.ex:68` |
| 信号 payload | `enrollment.completed` data 含 `enrollment_id/workspace_id/user_id/event_id\|course_id/idempotency_key`，**不含 title** | `enrollment.ex:617-640` |
| 监督树注册点 | `application.ex` children，`SponsorshipEndedSubscriber` 为先例 | `application.ex` |

## 3. 关键决策（含与任务书字面的偏差及依据）

**D-1：幂等键加消费者作用域——`"enrollment.completed:<enrollment_id>:learning_instantiator"`。**
任务书字面键 `"enrollment.completed:"+enrollment_id` 与 `NotificationSubscriber` 已 claim 的裸键冲突（同一 `(signal_type, key)` 唯一索引，先到者消费，后者静默跳过——会导致两个订阅方随机一个失效）。仓库既有惯例是消费者作用域后缀（`sponsorship_ended` / `research_run_reaper` 两处先例）。采用惯例，语义不变：重复投递只种一个 run。

**D-2：学员授权落点 = 工具层 `authorize/4` + 新增 `StepAuthorization.enrolled_learner?/3` 判定函数。**
设计 §4.1 首句说「`StepAuthorization.authorize_signal` 增加学员豁免分支」，但 `authorize_signal/4` 拿不到 run（豁免需 `run.input_snapshot["enrollment_id"]`）；§4.1 实现落点句自洽地落在工具层 `authorize/4`。执行后者：既有 StepRole 判定先行，失败（任一原因）时对 learning run 补 enrollment 匹配；两次判定都失败才拒绝（fail-closed 语义不变）。判定逻辑本身（definition type 检查 + Enrollment 反查）作为公开函数放进 `StepAuthorization`——授权逻辑的单一归属模块。

**D-3：`Wrapper.check_membership` 对 `save_step_output` 一个工具后移（membership-deferred）。**
学员是非成员，不改 Wrapper 则永远进不了工具体，验收「学员本人写 facts」不可能成立。改动面：新增 `@membership_deferred_tools ~w(save_step_output)`，仅跳过成员门槛，**不**跳过 `workspace_id` 必填（D12 不变）。安全性不降级：非成员非学员仍被两道后续闸门拒绝——工具层 StepRole/学员判定 + Ash policy（成员 bypass / 学员分支 / OwnerOrAdmin 兜底）。其余工具门控语义零变化。

**D-4：learning run 用纯 `:start`（pending→running），不走 `:start_run`。**
协议形态下平台无执行步骤（设计 §5）；`:start_run` 会调 `Engine.run` 执行 node_def，语义错误。

**D-5：「末个 manual step」= run 绑定定义版本 `node_def["steps"]` 中最后一个 `type=="manual"` 的 `"id"`。**
node_def 数组顺序即拓扑顺序（jido_adapter 契约），且 run 经 `definition_id` 绑定版本行，取的是实例化时的定义快照。不依赖 Step 资源行序（Step 行在 learning 协议下可不配置——未配置 = 不限制）。无 manual step 的定义永不触发完成（skip，不报错）。

**D-6：停滞时钟 = `run.updated_at`。**
running 态下 facts 写入（`update_facts_for_mcp`）是唯一更新路径，`updated_at` 即「facts 最近新增时间」的可靠代理；完成流转会离开 running 态天然退出扫描。`updated_at < now - 7 天` → 提醒。收件人守卫：反查 enrollment 仍 `confirmed` 才提醒（报名取消但 run 未联动取消属 E-2 缺口，不提醒已取消学员）。去重靠 `NotificationWorker` 7 天 args-unique（args 含 run_id）——同一 run 7 天内至多提醒一次。

**D-7：停滞提醒模板 key `"learning_stagnation"` 只加 config.exs dev/test 占位；`runtime.exs` 不动。**
runtime.exs 用 `System.fetch_env!` 重建模板 map——加必需环境变量会让未注册模板的 prod 环境启动崩溃。生产注册属运营上线动作（设计 §4.4 原文）。未配置时投递路径返回 `:template_not_configured`，NotificationWorker 重试后丢弃，不影响扫描主流程。

**D-8：停滞入队走 `NotificationWorker`（48h 模式），不是直调 `NotificationService`。**
设计 §4.4「经 NotificationService 提醒（复用 48h 提醒 Oban 入队模式）」——48h 先例的投递执行体就是 NotificationWorker（内部调 NotificationService），异步化 + 唯一性 + stale 重查全由此获得。`NotificationWorker.stale_reminder?/1` 增加 `learning_stagnation` 分支：发送时重查 run 仍 `running` 才投递。

## 4. 实现切片与触动文件

**Slice 1 · LearningInstantiator（验收 1）**
- 新增 `backend/lib/cgc_2046/workflows/learning_instantiator.ex`：
  - GenServer + `JidoAdapter.subscribe("enrollment.completed", ...)`（ResearchInstantiator 骨架）。
  - `instantiate_from_signal(enrollment_id, data)`（同步公开，测试直调）：enrollment 存在且 `confirmed`（孤儿防护）→ 反查 Event/Course 拿 `workspace_id` + `title` → 取租户最新 published `type=learning` 定义（version desc + inserted_at desc，无则 warning skip 供对账）→ claim（D-1 键）→ `find_or_create`。
  - `launch(workspace_id, definition_id, input)` / `find_or_create_run`：`input_snapshot["key"] = "enrollment_<id>"`；同 key 非终态 run 存在 → 返回已有；否则 create + `:start`（D-4），创建前重读 enrollment 二次校验 confirmed（对齐 research BLOCKING 3 修复）。
  - 全链路 try/rescue best-effort，失败记日志不崩溃。
- 改 `backend/lib/cgc_2046/application.ex`：children 注册（`SponsorshipEndedSubscriber` 后，注释对齐先例）。

**Slice 2 · 学员授权 + variance（验收 2）**
- 新增 `backend/lib/cgc_2046/policies/actor_is_enrolled_learner.ex`：`Ash.Policy.SimpleCheck`，`match?/3` 从 `changeset.data`（WorkflowRun）取 `input_snapshot["enrollment_id"]` → Enrollment 存在、`status == :confirmed`、`user_id == actor.id`，且 run 定义 `type == :learning` → 放行；读失败/字段缺失 → false（fail-closed）。
- 改 `workflow_run.ex` policies：`update_facts_for_mcp` bypass 加 `authorize_if(Cgc2046.Policies.ActorIsEnrolledLearner)`（成员/平台管理员两行不动）。
- 改 `step_authorization.ex`：新增 `enrolled_learner?(actor, workspace_id, run)` 公开判定（授权逻辑归属模块；IO 在内、判定纯）。
- 改 `save_step_output.ex`：① schema 加可选 `reason`（string）；② `authorize/4` 学员兜底分支（D-2）；③ `merge_facts` 把 `reason` 并入同次浅合并（`Map.put(output, "reason", reason)` 当 is_binary；无 reason 不写该键）；④ `Ash.Error.Forbidden` 显式映射为 forbidden 文案（非成员非学员拒绝时不再报模糊 "failed to save"）。
- 改 `wrapper.ex`：`@membership_deferred_tools`（D-3）。

**Slice 3 · LearningProgressWorker（验收 3+4）**
- 新增 `backend/lib/cgc_2046/workers/learning_progress_worker.ex`：
  - `use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300, states: :incomplete]`（对齐 ApprovalExpiryWorker）。
  - `perform/1` = 完成扫描 + 停滞扫描，单记录失败记 warning 不中断整拍。
  - 完成扫描：`status == :running` 且 `definition.type == :learning`（关系过滤）→ 末个 manual step key（D-5）在 `run.facts` 中存在 → `:complete` action（`authorize?: false`，tenant=run.workspace_id）。
  - 停滞扫描：同过滤 + `updated_at < now-7d` → 反查 enrollment 仍 confirmed → 该学员 UserIdentity 逐身份入队（D-6/D-8）。
- 改 `notification_subscriber.ex`：新增 `enqueue_learning_stagnation_jobs(identities, user_id, run)`（`enqueue_reminder_jobs` 同款形状，template `"learning_stagnation"`，job_meta 含 `run_id` 供 args-unique）。
- 改 `notification_worker.ex`：`stale_reminder?/1` 加 `"learning_stagnation"` 分支（run 仍 running 才投递）。
- 改 `config/config.exs`：Cron crontab 加 `{"*/5 * * * *", Cgc2046.Workers.LearningProgressWorker}`；`miniprogram_templates` 三平台加 `"learning_stagnation"` dev 占位。

**Slice 4 · 测试（验收全四条）**
- 新增 `backend/test/cgc_2046/workflows/learning_flow_test.exs`（DataCase + Oban.Testing，真实 DB）：
  1. `enrollment.completed` → 实例化：run 创建、status `:running`、key `enrollment_<id>`、facts `%{}`。
  2. 幂等：重复投递 → 仍一个 run（claim 命中 + find_or_create 两层都断到）。
  3. 学员本人写 facts 带 reason → 落账本（`facts[step_key]["reason"]` 与 output 同层）；学员写配了 StepRole（非学员角色）的步骤仍放行（学员豁免分支生效的证据）。
  4. 非学员非成员写被拒；学员写**他人** learning run 被拒；学员写非 learning run 被拒。
  5. 末步 facts 已写 → worker 一拍后 `succeeded`；未写 → 仍 `running`。
  6. 停滞：`updated_at` 回填 8 天 → worker 一拍 → `assert_enqueued` NotificationWorker（template `"learning_stagnation"`）；新 run 不入队。
- 回归依赖：现有 `tools_test.exs`（Wrapper 门控）、`step_authorization*_test.exs`、`workflow_run_test.exs` 全绿。

**Slice 5 · 交付**
- 本计划文档随 PR 提交；`mix test` 全量、`mix format --check-formatted`、`mix compile --warnings-as-errors`。
- 推 `feat/learning-workflow`，开 PR（base develop），**停在 PR 不 merge**。

## 5. 假设与仍需确认（不阻断，按设计字面执行）

| # | 假设/开放点 | 处理方式 |
|---|---|---|
| A-1 | `enrollment.workspace_id` 与所属 Event/Course 的 workspace 恒等（租户反规范化） | 校验链按设计「反查 entity 拿 workspace_id」执行；title 也从 entity 取（payload 无 title） |
| A-2 | 学习定义的 Step 资源行可不存在（未配置 = 不限制）；授权账本锚是 node_def 的 step id | worker 末步判定走 node_def（D-5），不依赖 Step 行 |
| A-3 | 学习定义 node_def 可能极简（全 manual）；Engine 永不执行它（D-4 纯 `:start`） | 测试中定义用 2 个 manual step 的 node_def |
| A-4 | 对账规则登记无独立注册表文件——设计 §6 即登记处 | 本计划 + worker moduledoc 写明两条规则（confirmed enrollment 无 run / run 停滞 >7 天）随实现启用，E-10 消费 |
| A-5 | prod 模板 key 未注册前，停滞提醒投递会 `:template_not_configured` 重试后丢弃 | 设计 §4.4 原文「上线时登记」；PR body 标注运营 follow-up |

无阻断性不明。

## 6. 验证

```bash
cd backend
mix test                                  # 基线 763 passed，只能增
mix test test/cgc_2046/workflows/learning_flow_test.exs
mix format --check-formatted
mix compile --warnings-as-errors          # 无新警告
```

人工验收映射：验收 1→测试 1/2；验收 2→测试 3/4；验收 3→测试 5；验收 4→测试 6。

## 7. 回滚

纯新增 + 加性分支（无 schema 变更、无既有调用方签名变化；Wrapper 仅对一个工具后移成员门槛且后续闸门 fail-closed）。回滚 = revert 分支，无数据迁移、无外部状态残留。

## 8. 实施偏差记录（2026-08-14 实施中发现并解决）

| # | 偏差 | 根因 | 决策 |
|---|---|---|---|
| D-1 | **新增 `JidoAdapter.subscribe_detached/3`**（计划外，共享基建加性改动） | 全套件在注册 LearningInstantiator 后确定性拖垮（seed 0 固定 305 失败）：`subscribe/3` 的转发进程 `spawn_link` 到订阅 GenServer，测试沙箱下转发进程收到连接代理的 `:shutdown` 退出（`rescue` 拦不住退出信号）→ GenServer 连坐死 → 监督树重启预算（3 次/5s）耗尽 → **整树静默关闭**（`:shutdown` 退出无崩溃报告）→ Repo/Registry 全灭，后续测试大面积 `repo not started`。`enrollment.completed` 是全套件最热信号，新增订阅方把既有结构性隐患从「偶发」推过阈值 | 加性引入 `subscribe_detached`（`spawn` + `monitor`，转发进程崩溃隔离）；LearningInstantiator 收 `{:DOWN, ...}` 重建订阅。既有订阅方行为不变（不改 `subscribe/3`） |
| D-2 | 学员豁免的资源层实现为 **SimpleCheck 读 `changeset.data`**，非 FilterCheck/运行时 check | Ash 对 update 的运行时 `check/4` 复核查询只回填主键（其余属性 nil），数据依赖判定拿不到输入；filter 表达式无法跨 jsonb 键关联 Enrollment | `ActorIsEnrolledLearner` SimpleCheck 从 authorizer context 的 changeset.data 判定（strict 阶段，真实求值）；规则本体与工具层兜底共用 `StepAuthorization.enrolled_learner?/3`（单一实现，check 委托） |
| D-3 | `update_facts_for_mcp` bypass **前移**到通用 create/update policy 之前 | Ash 按序评估 policy：通用 policy 先失败则后续 bypass 不再求值（实测学员被 Forbidden 拦截） | 顺序调整 + 注释固化；成员/平台管理员语义不变 |
| D-4 | `save_step_output` 的 `fetch_run` 改 `authorize?: false` + 显式 Forbidden 映射 | 学员（非成员）走 read policy 读不到自己的 learning run，工具层会提前 404 | 读取不再充当门禁；授权由工具层 `authorize/4` + 资源层 bypass 双重判定（语义不变，非学员仍 Forbidden） |
| D-5 | 测试纪律改为「不停订阅方 + `await_run` 轮询 + fixture 顺序（enroll 早于 publish）」 | 崩溃隔离后 `terminate_child` 会泄漏转发进程（不再随 GenServer 死）；且异步投递的邮箱滞后使「定义后建」无法排除转发进程竞争 | 测试直调 `instantiate_from_signal/2` + 轮询等待（25ms×80）；断言与创建者无关（幂等殊途同归） |
| D-6 | 全套件基线实为 **793 passed**（任务书 763 已过期） | — | 验收以 793 + 9 新 = 802 为准 |

验证终态（worktree，真实命令）：

- `mix test --seed 0`（修复前确定性崩 305 的种子）→ **802 passed**
- `mix test`（随机种子）× 2 → **802 passed** × 2
- `mix format --check-formatted` → 干净；`mix compile --warnings-as-errors --force` → 无警告
