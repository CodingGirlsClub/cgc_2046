# L3 机制图 + L0 复核漂移取证底稿

> 取证：L3EngineScout（2026-08-16）· 基准：worktree `docs/diagram-taxonomy`（develop@72c5924）
> 汇总判定见 [DRIFT-REPORT.md](../DRIFT-REPORT.md) §5.4；本文件为证据底稿。
> 所有路径相对 worktree 根；`backend/lib/...` 简写为 `lib/...`。四态判定：**一致** / **图旧** / **悬空** / **图漏**。

## 1. signal-join-strategies.puml（L3 双信号 join 策略）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| 1.1 | v1 主路径 = Workflow 层 runic 原生 join（`react_until_satisfied`），不走 Agent 策略层 join | 完全一致：moduledoc 明示主路径走 `Runic.Workflow.react_until_satisfied/3`，Agent 策略层 join 因 F1 死锁被绕开；manual 步骤编译为 `signal_cond → signal_step → join → merge` 门控子图 | **一致** | `lib/cgc_2046/workflows/jido_adapter.ex:10-32,141-203,452-472` |
| 1.2 | 「F1 修复已定位（2026-08-01）…修复 POC 已验证 PASS；标准写法采用官方 Coordinator fan-in」 | 产品代码无 Coordinator、无 fan-in 修复踪迹（grep `Coordinator` 零命中）；实际决策是**永久绕开** Agent 策略层——`RunAgent` 退化为纯 checkpoint 载体（「无 Agent 生命周期/策略/信号路由」） | **悬空**（图把 POC 修复当作产品事实；码中不存在该路径） | `lib/cgc_2046/workflows/run_agent.ex:4-14`；grep 全库 `InstanceManager\|SignalMatch\|Coordinator` 仅注释命中 |
| 1.3 | 审批两段式时序：第一段 run 停在 waiting（persist pending 实体）→ 第二段审批信号 resume run → approval_gate 读回 pending → confirm 原子扣名额 | **报名/赞助根本不经过 WorkflowRun 引擎**。两段在码中 = Ash action 状态机两步：`create_enrollment`（prepare_policy → pending/直接 confirmed，SignalEmitter 事务内 outbox 发 `enrollment.submitted`/`completed`）→ `confirm_enrollment`（before_action `prepare_confirm`：`reserve_capacity` 条件 UPDATE + `claim_pending` CAS，成功后发 `approved`+`completed`）。图的「两段式 = 引擎内两段 run」形态不存在 | **图旧**（概念等价、载体已变：实体状态机 + 信号，无报名 workflow run） | `lib/cgc_2046/events/enrollment.ex:171-207,388-409,563-611`；`lib/cgc_2046/changes/signal_emitter.ex` |
| 1.4 | 适配层必须内置「多信号分批 feed」集成测试防回归 | 已落地：`human_step_test.exs` describe「多信号分批 feed（F1 死锁回归防护）」双人工步骤依次放行；jido_adapter_test 多信号序列 | **一致** | `backend/test/cgc_2046/workflows/human_step_test.exs:437-440`；`backend/test/cgc_2046/workflows/jido_adapter_test.ex:305-317` |
| 1.5 | 「与真实业务一致：实体存 DB，审批是更新实体状态，不是重放流程」 | 与 1.3 码现实吻合（confirm 是 CAS UPDATE，非流程重放） | **一致** | 同 1.3 |

**小结**：图的核心定性（Workflow 层主路径 + F1 规避）仍准确；但「两段式」与「F1 修复 PASS/Coordinator」两处叙述已落后于或超出产品现实。

## 2. confirm-flow.puml（L3 MCP 高风险工具确认流 D8）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| 2.1 | 高风险工具 → PendingOperation(pending，不落业务库) → 返回 `needs_confirmation{id,摘要}` → confirm(id) 才落库+审计 | 一致：`Confirmation.request/confirm/cancel`；「**无 confirm 不落库**」原文在 moduledoc；审计经 `Wrapper.log_call` → ToolCallLog | **一致** | `lib/cgc_2046/mcp/pending_operation.ex`（moduledoc）；`lib/cgc_2046/mcp/confirmation.ex`；`lib/cgc_2046/mcp/wrapper.ex` |
| 2.2 | 用户取消 → `PendingOperation → rejected` | 码状态机是 `pending → confirmed \| cancelled`（无 rejected）；取消 = `:cancelled` | **图旧**（状态名漂移） | `lib/cgc_2046/mcp/pending_operation.ex`（constraints one_of） |
| 2.3 | pending 超时清理（「编码阶段细化」） | 已细化为：默认 TTL **10 分钟**、过期**读时派生** `"expired"`（不落库、无清理 job）；confirm 时校验「本人 + pending + 未过期」 | **图旧**（机制已实现且形态不同：读时派生而非清理） | `lib/cgc_2046/mcp/pending_operation.ex`（@default_ttl_seconds 600）；`lib/cgc_2046/mcp/pending_operation/effective_status.ex`；`lib/cgc_2046/mcp/tools/confirm_operation.ex`（moduledoc） |
| 2.4 | 已知风险：auto_approve 模式 10s 倒计时自动决策（REVIEW-FINDINGS F8） | 全库 grep `auto_approve` 零命中——该模式在码中**不存在**（既未实现也未配置） | **悬空**（图/审查记录描述了不存在的机制） | grep backend 全域 `auto_approve\|10s\|countdown` 无命中 |
| 2.5 | 高风险工具示例「assign_role / create_invitation」 | MCP 确认流唯一注册执行器 = `create_invitation`（`execute/3` 单分派子句 + fallback 拒绝）；`assign_roles` 只是 Ash change，无 MCP 确认流工具。工具全集：create_invitation / get_step_output / get_workflow / get_workspace_context / list_members / save_step_output / confirm_operation / cancel_operation | **图旧**（高风险面比图窄：仅 1 工具走确认流） | `lib/cgc_2046/mcp/confirmation.ex:60-70`；`lib/cgc_2046/mcp/tools/`（目录清单） |

## 3. hibernate-thaw.puml（L3 waiting 持久化）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| 3.1 | hibernate 落 checkpoint（workflow state + thread pointer %{id,rev}），thaw rehydrate 完整 journal | 一致：`JidoAdapter.hibernate/thaw` 包装 `Jido.Persist`，storage=`JidoStoragePostgres`，三表 `jido_checkpoints / jido_thread_entries / jido_thread_meta`；`term_to_binary` bytea | **一致** | `lib/cgc_2046/workflows/jido_adapter.ex:34-41,614-640`；`lib/cgc_2046/workflows/jido_storage_postgres.ex` |
| 3.2 | rev 校验不匹配报 `:thread_mismatch` | 机制存在但错误名不同：`append_thread` 的 `check_expected_rev` + 唯一约束冲突 → `{:error, :conflict}` | **图旧**（细节漂移） | `lib/cgc_2046/workflows/jido_storage_postgres.ex:118-160` |
| 3.3 | 核心 API = `Jido.Agent.InstanceManager`（keyed singleton + storage 备份；stop → 自动 hibernate） | **无 InstanceManager**（grep 零命中）。载体是 `RunAgent`（最小 struct，无常驻进程）；「进程被回收」语义由「根本不驻留进程」替代——每次 resume 都 thaw 重建。图的进程生命周期叙述是 POC 形态 | **悬空**（该 API/进程模型在产品中不存在；存储机制等价） | `lib/cgc_2046/workflows/run_agent.ex`；`lib/cgc_2046/workflows/jido_adapter.ex:32`（「阶段 4 接 SignalMatch 完整形态」仅是展望注释） |
| 3.4 | checkpoint 生命周期由谁驱动 | 图未画：产品层 `CheckpointLifecycle` 单源——waiting→hibernate（严格，失败上抛）、终态→delete（宽松，日志不阻塞）；含 `:expired` 终态 | **图漏** | `lib/cgc_2046/workflows/checkpoint_lifecycle.ex`；`lib/cgc_2046/workflows/workflow_run.ex:516-624` |
| 3.5 | 「未覆盖：deadline 到点唤醒 → cancel 路径（🟡 待 v1 补集成测试）」（REVIEW-FINDINGS F2） | **已实现**：`ApprovalExpiryWorker`（Oban cron 每 5 分钟）扫 `WorkflowRun status=waiting` + `ApprovalDeadline.overdue?`（updated_at + definition.approval_timeout，nil=永不）→ `:expire`（pending/waiting→expired + checkpoint 清理）；moduledoc 自述即「POC-2 G1 遗留缺口的 v1 唤醒机制」；集成测试 describe「POC-2 G1 补测：hibernate→thaw→cancel 链路」 | **图旧**（图注待办已完成；且终态为 expired 非 cancelled） | `lib/cgc_2046/workers/approval_expiry_worker.ex:19-31,63-99,166-171`；`lib/cgc_2046/approval_deadline.ex`；`lib/cgc_2046/workflows/workflow_run.ex:393-417`；`backend/config/config.exs:110`；`backend/test/cgc_2046/workers/approval_expiry_worker_test.exs:356-359` |
| 3.6 | 循环 hibernate/thaw、恢复期信号不丢不重（A4/A5） | 循环放行测试存在；「不丢不重」由 SignalIdempotency claim + SignalLog 审计承担 | **一致** | `backend/test/cgc_2046/workflows/human_step_test.exs:227-231`；`lib/cgc_2046/workflows/signal_idempotency.ex` |

## 4. key-routing-isolation.puml（L3 实例 key 路由与隔离）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| 4.1 | InstanceManager keyed singleton（key=event_#/course_#），`build/0` 模板实例化 AgentServer | 无 InstanceManager/AgentServer。实例 = **WorkflowRun DB 行**；instance key `"event_#{id}"`/`"course_#{id}"` 写入 `input_snapshot["key"]`；模板实例化 = `find_or_create_and_start`（create + start_run） | **悬空**（机制载体不存在；key 约定与幂等语义保留） | `lib/cgc_2046/workflows/research_instantiator.ex`（instance_key/1）；`lib/cgc_2046/workflows/workflow_run.ex:695-739` |
| 4.2 | SignalMatch 按 key 前缀路由信号到对应实例 | 无按前缀路由。信号经总线 → 订阅方按 `data["event_id"/"course_id"]` 解析 → DB 查询 `input_snapshot["key"]` 定位 run；run 内信号门控按 `signal_type`（`workflow.<step_key>`）匹配 | **悬空** | `lib/cgc_2046/workflows/research_run_reaper.ex:33-52`；`lib/cgc_2046/workflows/jido_adapter.ex:553-589`（feed_signal） |
| 4.3 | 隔离 = AgentServer 进程 + strategy state | 隔离 = DB 行 + 租户（multitenancy workspace_id）+ 每请求内执行；无常驻进程 | **图旧** | 同 4.1/4.2 |
| 4.4 | 生命周期：event.launched → get（幂等）；idle 超时 hibernate；event.ended → stop（可重新实例化） | 语义基本一致：「幂等 get」= `existing_run`（definition_id + 非终态 + key）查询去重，终态后可重建；「idle 超时 hibernate」实为 **waiting 即 hibernate**（无 idle 超时）；「event.ended → stop」= `ResearchRunReaper` 订阅 ended → `WorkflowRun :cancel`（含 checkpoint 清理），限定 type=research | **部分一致/图旧**（idle-超时→即时的细节漂移） | `lib/cgc_2046/workflows/workflow_run.ex:727-739`；`lib/cgc_2046/workflows/checkpoint_lifecycle.ex`；`lib/cgc_2046/workflows/research_run_reaper.ex:1-52` |
| 4.5 | partition = registry key {partition,key}；partition = Workspace | partition=workspace 一致（`Jido.partition_key(run_id, partition)`，partition=tenant）；但 {partition,key} registry 不存在，key 只活在 input_snapshot JSON | **部分一致** | `lib/cgc_2046/workflows/jido_adapter.ex:622-640`；`lib/cgc_2046/workflows/workflow_definition.ex`（multitenancy 注释「每 workspace = 一个 Jido partition」） |
| 4.6 | （任务书）幂等三层：request_id + 业务唯一索引 + signal idempotency_key；Redis 是否接线 | ①`Plug.RequestId` 存在但只是 Phoenix 默认日志关联 plug，**不承担幂等**（`cgc_2046_web/endpoint.ex:44`）；②业务唯一索引落地：enrollment 两个部分唯一索引（pending/confirmed 范围）+ `identity_wheres_to_sql`（`events/enrollment.ex:135-141,250-253`）；③`SignalIdempotency` Postgres `(signal_type, idempotency_key)` 唯一约束 claim（`workflows/signal_idempotency.ex`）。**Redis 未接线**：全库无 Redix（仅注释提及「生产用 Postgres 或 Redis」），F3 的二选一已拍板 Postgres；另有 ETS 限流器（signIn/signUp）显式标注「多节点时换 Redis」 | **一致（选型 Postgres）；request_id 层名不符实** | grep `Redix\|redis`：仅 `signal_idempotency.ex:6-7`、`rate_limit.ex:5-6` 注释 |

## 5. template-parameterization.puml（L3 模板参数化）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| 5.1 | 无占位符替换；run input → Fact → ActionNode 把 fact value merge 进 node params → Action.run(params) | 方向一致：`Engine.run(node_def, input)` → `react_until_satisfied(workflow, input)`（input 作根 fact 注入）；ActionNode 建节点时 params 为空 `{}`，「fact→params」合并发生在 runic 库内部（适配层无显式 merge 代码，与图叙述的层次一致） | **一致** | `lib/cgc_2046/workflows/engine.ex:118-151`；`lib/cgc_2046/workflows/jido_adapter.ex:129-133,561-566` |
| 5.2 | Action schema 声明 course_id/event_id required（POC actions） | 产品侧 schema 前置校验落在 `Engine.prepare_all`（step `input_schema` 逐字段类型校验，失败 `{:prepare_failed, ...}` 不进执行）；Action 侧由 StepHandlerRegistry 白名单 + 各 handler 自持 schema | **一致 + 图漏**（码多出 input_schema 校验层与注册表白名单层） | `lib/cgc_2046/workflows/engine.ex:14-90`；`lib/cgc_2046/workflows/step_handler_registry.ex` |
| 5.3 | 同一定义两条实例按输入定向产出；Event/Course 上下文作 run input | 一致：ResearchInstantiator 按 entity 构造 input（event_id/course_id/title/research_requirements），key 派生自 entity | **一致** | `lib/cgc_2046/workflows/research_instantiator.ex:104-121` |
| 5.4 | 未来用 Workflow.merge/2 组合片段 | 无使用（图自身即「未来」，不算悬空） | n/a | — |

## 6. L0 复核：architecture-overview.puml

**成立的部分**：四层划分（用户侧 BYO / 网站=业务中枢+MCP server+引擎 / Ash 业务资源 / Jido 引擎）与依赖方向（workflow → Ash Action；业务侧只发 Signal）与码一致；`anubis_mcp` 名实相符（`Cgc2046.Mcp.Server`，streamable HTTP，经 Phoenix forward，`application.ex` + `router.ex :mcp` pipeline，含 OpenClacky ≤1.5.6 协议兼容 shim `mcp_protocol_compat_plug.ex`——B 通道真实存在的佐证）；Step 四分类、partition=Workspace、Thread journal 三表均在码中。

**漂移/缺失**：
1. **WorkflowRun 状态机图漏 `:expired`**——码是 7 态 `pending/running/waiting/succeeded/failed/cancelled/expired`（F2/F7 落地新增）。证据：`workflows/workflow_run.ex:59,393-417`。
2. **「WorkflowDefinition 六族」实为 3 实 + 3 空**——type 枚举六族与码一致（`workflow_definition.ex:44-51`），但全库无任何 enrollment/sponsorship/platform_ops 类型定义的创建路径（grep 仅对账 worker 注释命中）；实际有 instantiator/定义消费的只有 learning / research / speaker_invitation。报名、赞助是纯 Ash 状态机（见 1.3）。图把六族画成并列实存 → **图旧**。
3. **「MCP 所有工具必填 workspace_id（D12）」绝对化表述与码例外冲突**——`Wrapper` 有 `@workspace_optional`（confirm/cancel_operation）与 `@membership_deferred`（save_step_output，授权下沉到 Enrollment）。证据：`mcp/wrapper.ex:16-25`。
4. **业务资源清单缺一批运行时资源**——码还有 JoinRequest / WorkspaceApplication / Invitation / PortfolioItem / AdminActionLog / SignalLog / SignalIdempotency / Notification(Consent) / PendingOperation / ToolCallLog / Reconciliation.Finding / miniprogram_code。证据：`lib/cgc_2046/` 目录结构。
5. **引擎框内「Thread journal 审计」表述偏差**——产品审计真源是 `SignalLog`（ADR-0003「审计走事件订阅」，`engine.ex` resume doc），thread journal 是存储细节非审计面。证据：`workflows/signal_log.ex`；`workflows/engine.ex:168-175`。
6. **整层缺失**：Oban worker 族 + cron、对账（Reconciliation）、审批期限（ApprovalDeadline）、通知扇出、信号总线与六订阅方、小程序通道（详见 §8 演进清单）。

## 7. L0 复核：system-context.puml

**成立的部分**：8 角色（Visitor/Learner/Tutor/Volunteer/Owner-Admin/Sponsor/Speaker/PlatformAdmin）与形态 X（网站无对话/执行页）在码中有对应权限面（`policies/` 13 个 policy + `rbac.ex` + `accounts/role.ex`）；「聊天与 Agent 执行在 OpenClacky 经 MCP」与码一致（网站侧无对话路由；Web 面 = GraphQL `/api` + AshAdmin `/ops` + `/mcp`）。

**缺失/错误**：
1. **缺小程序渠道**——码有完整通道：①登录：`accounts/strategies/miniprogram.ex`（AshAuthentication 自定义 strategy）+ `miniprogram/client.ex`（wechat/tt/xhs 三平台 code2session、手机号解密、小程序码生成）+ `miniprogram_code.ex`；②通知回流：`notification_consent.ex`（订阅消息授权）经 NotificationFanout/NotificationWorker 扇出。system-context 8 角色全部只挂「网站/OpenClacky」，无小程序 Actor/系统 → **图漏**。
2. **缺邮件外部系统**——Swoosh + SendCloud 自定义 adapter（`swoosh_adapters/send_cloud.ex`、`mailer.ex`）是真实外发通道，L0 未画。
3. **「网站页面（工作台/报名页/审批页/审计页）」表述**——码侧是 Next.js 前端 + GraphQL（router 注释「前端是 Next.js，无项目级 HTML layout」），服务端仅 AshAdmin `/ops`；审批页数据面 = `events/pending_approvals.ex`（跨工作台审批待办聚合 + 角标计数）。图把页面画成网站内部组件可接受，但「审计页」在码中是 PlatformAdmin 的 `/ops` + 对账 findings，非普通 Owner 面 → **图旧（弱）**。
4. **「B 通道 = 唯一对外通道」需限定为「Agent 侧唯一」**——对浏览器/Next.js 是 GraphQL `/api`，对小程序是微信/抖音/小红书服务端 API，均非 MCP。

## 8. 机制层新演进清单（码有图无）

1. **进程内信号总线 + 六订阅方**：`Jido.Signal.Bus`（`:cgc_workflow_bus`，Application 挂载）+ `JidoAdapter.publish/subscribe`（spawn 转发进程，崩溃隔离 + monitor 反向收割）；订阅方六个：ResearchInstantiator、ResearchRunReaper、SponsorshipEndedSubscriber、LearningInstantiator、NotificationSubscriber、SpeakerSubscriber。证据：`lib/cgc_2046/application.ex`；`workflows/jido_adapter.ex:663-745`。
2. **SignalSubscriber 骨架**：四种幂等策略（claim_first / claim_in_handle / claim_after_effects / state_based）+ DOWN 重订阅 + 投递 telemetry `[:cgc2046,:signal,:deliver]`。证据：`workflows/signal_subscriber.ex:13-27`。
3. **事务内 Oban outbox**：`Changes.SignalEmitter`——实体终态同事务入队 `SignalPublishWorker`（失败即回滚），payload 规范 `idempotency_key="<type>:<record_id>"`。证据：`lib/cgc_2046/changes/signal_emitter.ex`。
4. **Oban worker 族（7 个）+ cron**：ApprovalExpiryWorker `*/5`、EventLifecycleWorker `*/5`、LearningProgressWorker `*/5`、ApprovalReminderWorker 每小时（48h 窗口，Enrollment/Sponsorship 提醒 + waiting run 审计 SignalLog）、ReconciliationScanWorker `*/10`；事件驱动 SignalPublishWorker / NotificationWorker；queues maintenance/notifications + Pruner 7 天。证据：`backend/config/config.exs:103-116`；`lib/cgc_2046/workers/`（7 文件）。
5. **对账子系统**：七规则扫描（confirmed 无 run / pending 无 deadline / 死信信号 / open 无教研定义 / closed 实体挂非终态 run / 死信 job / learning run 停滞）→ `reconciliation_findings` upsert-刷新-消解即删。证据：`workers/reconciliation_scan_worker.ex:8-45`；`reconciliation/finding.ex`。
6. **审批期限体系（F2/F7 落地）**：`ApprovalDeadline` 唯一真源（列实体读列；WorkflowRun = updated_at + definition.approval_timeout，nil=永不过期）+ `WorkflowDefinition.approval_timeout` 参数 + expire 转换族 + 48h 提醒。证据：`lib/cgc_2046/approval_deadline.ex`；`workflows/workflow_definition.ex:107-112`；`workers/approval_expiry_worker.ex`；`workers/approval_reminder_worker.ex`。
7. **CheckpointLifecycle 单源**（写严格/清宽松，ADR-0003 checkpoint 剥离引擎核心）。证据：`workflows/checkpoint_lifecycle.ex`。
8. **通知扇出面**：`NotificationFanout`（收件人解析 :manage/{:roles,...} + Oban 入队唯一归属 + reminder_7d unique 预设 + telemetry）+ NotificationService/Worker + SendCloud。证据：`lib/cgc_2046/notification_fanout.ex`。
9. **小程序通道**（见 L0-7.1）。证据：`accounts/strategies/miniprogram.ex`；`miniprogram/client.ex`；`miniprogram_code.ex`；`notification_consent.ex`。
10. **引擎安全硬化族（/check SC2 系列，图全无）**：StepHandlerRegistry action 白名单（SC2-001/011）、step id 正则限原子（SC2-002）、signal_type 字符串匹配不建原子（SC2-003）、门控组件显式 hash 防顶点合并串门（SC2-009）、内部门控组件过滤不泄产品层（SC2-010）。证据：`workflows/jido_adapter.ex`（对应注释）；`workflows/step_handler_registry.ex`。
11. **MCP 运行时设施**：ToolCallLog 审计 + Redact + 连接 token + PendingOperation 确认流（见 §2）+ Wrapper 例外清单。证据：`lib/cgc_2046/mcp/`。
12. **并发与幂等底座**：Enrollment 条件 UPDATE 原子扣名额/释放 + CAS claim_pending + 部分唯一索引；SignalIdempotency Postgres 唯一约束；WorkflowRun 乐观锁 version + facts 持久化合并（stale engine facts 被 persisted 覆盖）。证据：`events/enrollment.ex:563-667`；`workflows/signal_idempotency.ex`；`workflows/workflow_run.ex:343,636-639`。
13. **Web 侧基础设施**：ETS 限流器（signIn/signUp 5 次/15 分钟）+ `Plug.RequestId` + CORS。证据：`cgc_2046_web/plugs/rate_limit.ex`；`cgc_2046_web/endpoint.ex:44`。

## 结论速览

- **真悬空**（图描述的机制码中不存在）：InstanceManager keyed singleton / SignalMatch 按前缀路由（key-routing 4.1-4.2、hibernate 3.3）、Coordinator fan-in「标准写法」（signal-join 1.2）、auto_approve 10s 倒计时（confirm-flow 2.4）。
- **最典型的图旧**：①hibernate-thaw「deadline 唤醒未覆盖」→ 已由 ApprovalExpiryWorker + :expired 全链路实现并有补测；②报名/赞助「两段式 workflow run」→ 实为 Ash 状态机 + 信号，不经引擎；③PendingOperation rejected/清理 → cancelled/读时派生 expired。
- **L0 最大缺口**：小程序渠道（登录+通知）、Oban/对账/审批期限/通知扇出/总线订阅方等整个运行时机制层、WorkflowRun :expired 态、六族定义 3 实 3 空。
