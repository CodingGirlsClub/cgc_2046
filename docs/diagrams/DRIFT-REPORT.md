# CGC-2046 架构图资产与漂移对照报告

> 版本：2026-08-16 v1 · 基准：`develop@72c5924` · 取证 worktree：`docs/diagram-taxonomy`（b9d8bcb）
> 定位：内部工程报告，可直接改编为对外分享。叙事弧：**问题 → 方法 → 发现 → 判断 → 行动 → 复用**。

---

## 1. 背景：为什么要做这件事

`docs/diagrams/` 下的 16 张 L0–L4 架构图（PlantUML）基于 `docs/00-CGC平台设计总纲.md` 与 `docs/01-定稿设计/` 绘制，是项目早期对架构的**设计快照**。项目快速迭代后产生了两个风险：

1. **图过时**：codebase 演进（新顶层单元、新 workflow、新机制）没有回写到图，图逐渐失去参考价值；
2. **架构变形无感知**：代码"做着做着"偏离原设计——老架构未必实现不了，但没人有意识地拍板过"我们就是要换路"。

危险的不是漂移本身，而是**漂移不被看见、不被裁决**。本报告的目的是把漂移显性化、分类、给出处置建议，并沉淀一套可持续的对照流程。

## 2. 方法论：六层体系

整套实践按结果导向（一份可分享报告）反向构建为六层漏斗：

| 层 | 回答的问题 | 工具/理论 | 本项目产出 |
|---|---|---|---|
| ① 理论层 | 业界怎么用图描述项目 | C4 model / arc42 / 4+1 视图 / 事件驱动文档实践（EventCatalog） | 类别并集清单 |
| ② 分类层 | 用什么尺子量本项目 | 业界类别 × L0–L4 映射，裁剪（System Landscape/Component 级判不适用） | README「二」对照表 |
| ③ 资产层 | 尺子上的刻度 | 每张图带「事实来源」锚点头注释 | 21 张 `.puml`（16 老 + 5 新） |
| ④ 对照层 | 图说的和码做的一致吗 | 四态判定法（见 §5） | 本报告 §5 |
| ⑤ 评审层 | 架构本身合理吗 | 视图一致性检查 / ATAM 质量属性 / fitness function / 反模式扫描 | 本报告 §6 |
| ⑥ 行动层 | 然后呢 | 裁决记录 + 还账清单 + 防漂移流程 | 本报告 §7 |

关键取舍：**裁剪比全量重要**。C4 的 System Landscape（单产品单团队）与 Component 级（规模未到）明确判"不适用"并写明理由——体系完备性的价值在于"知道哪些不用做"。

## 3. 分类体系对标（②层结果）

业界标准图类别与本项目 L0–L4 的映射及覆盖状态（详见 [README.md](./README.md)「二」）：

- ✅ 已覆盖：系统上下文、逻辑分层、领域模型（结构）、业务流程、状态机、运行时时序、幂等横切、用户旅程、决策记录（ADR 文字资产）、风险清单（REVIEW-FINDINGS）
- 本轮补齐 5 类：**容器拓扑**（C4 Container）、**部署视图**（C4 Deployment）、**接口契约**（arc42 §3.2）、**信号/事件目录**（事件驱动实践）、**鉴权/租户/审计横切**（arc42 §7）
- 显式判不做 2 类：System Landscape、C4 Component 级

## 4. 补图实践：事实来源驱动画图（③层结果）

5 张新图全部**以 codebase 现状为事实来源**绘制（老图以设计文档为来源），头部注释逐条列出取证的文件。这一差异本身就是方法：新图 = 码的快照，老图 = 设计意图的快照，**两者的差集就是漂移的初步清单**。

| 新图 | 取证要点 |
|---|---|
| `container-topology` | 仓库顶层结构、config.exs（Oban PG-backed、无 Redix）、router.ex 挂载、next.config.ts rewrite |
| `deployment-view` | 运维文档「无部署信号」现状声明 + SendCloud 五值注入契约 |
| `api-contracts` | router 四面挂载 + schema.graphql 根字段计数（Query 36 / Mutation 60+）+ Mcp.Server 8 工具 |
| `signal-event-catalog` | signal_emitter 生产契约 + signal_subscriber 骨架 + 六订阅方 patterns + 幂等四策略 |
| `auth-tenant-isolation` | mcp/token + tool_call_log + policies + D5/D6/D9/D12/D13 决策 |

## 5. 漂移对照发现（④层结果）

### 5.0 判定语言

| 判定 | 含义 | 处置 |
|---|---|---|
| 一致 | 图码相符 | 无 |
| 图旧（良性演进） | 码是对的，图落后 | 更新图 |
| 腐蚀（欠债） | 码偏离设计且无人拍板 | Leader 裁决：还账 or 认账改图 |
| 悬空（设计未落地） | 图有码无 | 标注 roadmap 或从图删除 |

### 5.1 补图时已锁定的新漂移（第一手证据）

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| D-A | `key-routing-isolation`：幂等三层承载「Postgres/Redis」 | config 无 Redix；claim 落 `signal_idempotency` Postgres 表，Redis 仅 moduledoc 备选 | 图旧（表述过宽） | `backend/lib/cgc_2046/workflows/signal_idempotency.ex`、`backend/config/*.exs` |
| D-B | 老图隐含已部署/将部署的生产形态 | 仓库无 vercel/fly/docker 配置；运维文档明言「当前无部署信号」 | 图旧（超前现实） | `docs/运维/邮件与CD环境注入.md` §2 |
| D-C | 老图：signal 由产品层 action 直接 feed 引擎 | 实际演进为 PubSub 进程内总线 + Oban 重投 + 六订阅方幂等四策略（PR-B 深化） | 图旧（演进未回写） | `signal_subscriber.ex` moduledoc、`workers/signal_publish_worker.ex` |

### 5.2 L1 — 领域模型（ER / 类图 vs Ash 资源）（详证见 [DRIFT-EVIDENCE/L1-domain-model.md](./DRIFT-EVIDENCE/L1-domain-model.md)）

**资源全集**：32 个 Ash 资源，3 个 Domain——`GlobalApi` 15（accounts + miniprogram）、`Api` 14（workflows + reconciliation + events）、`Mcp` 3。图上结构关系断言大部分成立（五角色枚举、invite_code/token_hash 唯一约束、二选一 FK、partial unique index 均有代码对应）。

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| L1-1 | Agent / AgentRole / AgentRun 三实体 | **无任何资源**。`Step.agent_id` 成为无目标表的悬空引用；AgentRun 仅剩内存态 Jido 载体（`run_agent.ex`） | 悬空 | `backend/lib/cgc_2046/workflows/run_agent.ex`、全库 grep 无 Agent 资源 |
| L1-2 | ResearchOutput 实体 | 无资源；产出落 `WorkflowRun.facts` | 悬空（形态已变） | `workflow_run.ex` facts 持久化 |
| L1-3 | SponsorshipTier 独立实体 | 无表；档位为 Event/Workspace 内嵌 `sponsorship_tiers` json + 纯函数模块 | 悬空（形态已变） | `events/event.ex` |
| L1-4 | Event/Course.materials_review_required 字段 | 全库不存在 | 悬空 | grep 无命中 |
| L1-5 | 各实体状态枚举 | Sponsorship/Enrollment/Invitation/JoinRequest/WorkflowRun 均新增 `:expired`；Enrollment 实为 `pending/confirmed/rejected/expired/cancelled`（图的 draft/submitted 不存在，码直接落 pending/confirmed） | 图旧 | `events/enrollment.ex:58`、`events/sponsorship.ex:84` |
| L1-6 | PendingOperation 含 rejected；ToolCallLog 含 denied/pending 等 | 实为 `pending|confirmed|cancelled` / `ok|error|needs_confirmation|forbidden` | 图旧 | `mcp/pending_operation.ex`、`mcp/tool_call_log.ex` |
| L1-7 | Step.type `subworkflow`；version string | 实为 `:sub_workflow`；version integer | 图旧（弱） | `workflows/step.ex`、`workflow_definition.ex` |
| L1-8 | ——（图漏） | 9 个新资源未入图：SponsorshipDelivery（履约账本）、SignalIdempotency、Reconciliation.Finding、WorkspaceApplication、AdminActionLog、PortfolioItem、Mcp.Token、Miniprogram.Code、Miniprogram.NotificationConsent | 图漏（良性演进） | 各资源文件 |
| L1-9 | —— | payments 域在本基线不存在（F4 支付状态全库无预留；`feat/payment-loop` 分支正在开发，不在本报告基准内） | 悬空（有意的 v1 范围） | develop 基线 grep |

### 5.3 L2 — 业务工作流（workflow 图 vs 引擎实现）（详证见 [DRIFT-EVIDENCE/L2-workflows.md](./DRIFT-EVIDENCE/L2-workflows.md)）

**一句话**：WorkflowDefinition.type 六族里只有 **3 族真实跑在引擎上**（research / speaker_invitation / learning）；enrollment/sponsorship 是**实体自序贯**（Ash 状态机 + 信号，不建 run——v1 有意拍板，`sponsorship.ex:226` 注释明示「workflow_run_id 供二期引擎化」），platform_ops 有枚举无任何驱动。老图把六族画成并列实存的 workflow 编排，是最深的一处图旧。

| # | 图断言 | 码现实 | 判定 | 证据 |
|---|---|---|---|---|
| L2-1 | 报名 = 三段式 workflow run（S0–S12） | 两段在码中 = Ash action 状态机两步：create（policy 判定落 pending/confirmed）→ confirm（`reserve_capacity` 条件 UPDATE + `claim_pending` CAS），信号事务内 outbox 发出；**不经 WorkflowRun 引擎** | 图旧（概念等价、载体已变） | `events/enrollment.ex:171-207,388-409,563-611`、`changes/signal_emitter.ex` |
| L2-2 | 赞助 = 审批两段式 workflow | 同上，实体自序贯；v1 不收款、无 payment 状态 | 图旧（同因） | `events/sponsorship.ex:84,226` |
| L2-3 | WorkflowRun 6 态（pending/running/waiting/succeeded/failed/cancelled） | 7 态：多 `:expired`；动作族含 expire | 图旧 | `workflows/workflow_run.ex:59,393-417` |
| L2-4 | 「deadline 到点唤醒 → cancel 🟡 待补测」（REVIEW-FINDINGS F2） | **已闭环**：ApprovalExpiryWorker（Oban */5min）扫 waiting + ApprovalDeadline.overdue? → `:expire`（终态 expired 非 cancelled），集成测试自述即「POC-2 G1 补测」 | 图旧（待办已完成且形态不同） | `workers/approval_expiry_worker.ex:63-99`、`approval_deadline.ex` |
| L2-5 | Enrollment 状态机含 draft/submitted | 码直接落 pending（open）/ confirmed；多 expired | 图旧 | `events/enrollment.ex:363-398` |
| L2-6 | SpeakerInvitation 含 expired；InviteBatch 含 exhausted | 两者码中均无此态（SPI 四态；IVB 配额尽走 remaining_quota 条件 UPDATE） | 悬空（设计未落地） | `events/speaker_invitation.ex:38`、`events/invite_batch.ex:53` |
| L2-7 | ——（图漏） | **learning workflow 码有图无**：LearningInstantiator 订阅 enrollment.completed 建 run，但学习是协议非 DAG——纯 `:start` 流转不经 Engine/runic | 图漏（重大架构演进） | `workflows/learning_instantiator.ex`、`learning_progress.ex` |
| L2-8 | —— | course-issue 学习闭环仅设计定稿（2026-08-16 v1.0），无实现 | 设计快照（正常） | `docs/01-定稿设计/课程issue学习闭环详细设计.md` |
| L2-9 | README 自述三段式 S0–S12 | 与实际 puml 分段（S1–S8/A1–A5）不一致 | README↔图内部漂移 | `README.md` vs `workflow-enrollment.puml` |

### 5.4 L3 — 引擎/机制 + L0 复核

**逐图判定速览**（详证见 [DRIFT-EVIDENCE/L3-engine-l0.md](./DRIFT-EVIDENCE/L3-engine-l0.md)）：

| 图 | 一致主轴 | 判定要点 |
|---|---|---|
| `signal-join-strategies` | Workflow 层 runic 原生 join 主路径 ✅；多信号回归测试已落地 ✅ | 「F1 修复 PASS / 官方 Coordinator fan-in 标准写法」**悬空**——产品码无 Coordinator，实际决策是永久绕开 Agent 策略层（`run_agent.ex` 退化为纯 checkpoint 载体） |
| `confirm-flow` | two-tool 确认流主干（无 confirm 不落库）✅ | rejected→实为 cancelled（图旧）；TTL 已细化为 600s + 读时派生 expired（图旧）；**auto_approve 10s 倒计时全库无实现（悬空，F8 描述了不存在的机制）**；高风险面实况 = 仅 create_invitation 一工具走确认流 |
| `hibernate-thaw` | checkpoint 三表（jido_checkpoints/thread_entries/thread_meta）+ rev 校验 ✅ | `Jido.Agent.InstanceManager` keyed singleton **悬空**——产品无常驻进程，每次 resume thaw 重建；「deadline 未覆盖」图旧（已闭环，见 L2-4）；CheckpointLifecycle 单源（waiting→hibernate 严格 / 终态→delete 宽松）图漏 |
| `key-routing-isolation` | 幂等三层选型 Postgres ✅（业务唯一索引 + signal claim 均落地） | InstanceManager keyed singleton / SignalMatch 前缀路由**悬空**——key 约定活在 `input_snapshot["key"]` JSON，路由靠订阅方解析 payload 查 DB；「request_id 幂等层」名不符实（Plug.RequestId 只做日志关联）；隔离载体 = DB 行 + 租户 + 每请求执行（图旧） |
| `template-parameterization` | run input → 根 fact 注入、实例隔离 ✅ | 码多出 input_schema 前置校验 + StepHandlerRegistry 白名单两层（图漏，属增强） |

**L0 复核**（`architecture-overview` / `system-context`）：四层划分、依赖方向、Step 四分类、partition=Workspace 均仍成立。缺口：①小程序渠道整个缺失（登录 strategy + 三平台 client + 通知 consent 回流）；②Oban 七 worker/cron、对账七规则、审批期限、通知扇出、信号总线六订阅方——**整个运行时机制层无图承载**（已由本轮新图部分覆盖）；③WorkflowRun :expired 未入图；④「六族定义」3 实 3 空；⑤「MCP 所有工具必填 workspace_id（D12）」绝对化——wrapper 实有例外清单（confirm/cancel 免 workspace、save_step_output 授权下沉 Enrollment）；⑥「审计页」实为 PlatformAdmin /ops + 对账 findings，非 Owner 面；⑦审计真源是 SignalLog（ADR-0003），thread journal 是存储细节非审计面。

### 5.5 漂移汇总

| 维度 | 计数 | 分布 |
|---|---|---|
| 一致主轴 | 6 条 | join 主路径 / checkpoint 三表 / 模板参数化 / 确认流主干 / 幂等选型 Postgres / 租户隔离模型 |
| 图旧 | ~20 条 | 集中两大叙事：**报名/赞助「两段式 workflow run」实为实体状态机 + 信号**；**F2 deadline 唤醒已闭环（expired 态 + ApprovalExpiryWorker）**。其余为枚举漂移（:expired 族）、状态命名（cancelled/rejected）、载体漂移（进程→DB 行） |
| 悬空 | ~10 条 | 四组 POC 遗留词汇（InstanceManager / SignalMatch / Coordinator fan-in / auto_approve）；三组未落地实体（Agent 族 / ResearchOutput / SponsorshipTier 表）；F4 支付状态；platform_ops |
| 图漏（良性演进） | ~25 条 | 9 新资源 + learning 绕引擎 + 机制层 13 项（总线/六订阅方/outbox/七 worker/对账/审批期限/扇出/SC2 安全硬化族…）+ 小程序渠道 |

**总裁决印象**：无"腐蚀"级漂移——所有重大偏离都能找到拍板痕迹（sponsorship.ex:226 注释、ADR-0003、F2/F7 决策记录）。这个 codebase 的问题不是架构腐化，而是**拍板没有回写到图**。老图最系统的两个失真来源：①把 POC 探索形态当产品事实画进图；②设计文档的"将来时"被画成"现在时"。

## 6. 评审层初判（⑤层结果）

漂移对照回答"图和码一致吗"；评审层回答"**架构本身合理吗**"。本轮用四个工具做初判（全面 ATAM 不在本轮范围）：

### 6.1 视图一致性检查（图与图互为测试用例）


本轮取证已能填充的实例：
- **ER 聚合 ↔ workflow 驱动**：Enrollment/Sponsorship 聚合存在但**无 workflow 驱动**（实体自序贯）——L1 图与 L2 图对同一事实的叙述互相矛盾（L1 暗示被编排，L2 画成被编排，码都不是）；
- **signal 目录 ↔ L2 生产者**：SignalEmitter 17 类型全部可溯源到实体状态机 ✅（新图已对齐）；孤儿信号（speaker.declined、sponsorship.*）在 signal-event-catalog 已显式标注；
- **context actor ↔ journeys**：8 角色两图对齐 ✅，但**小程序用户渠道在 context 与 journeys 双双缺失**——视图一致性检查的价值即在此：单独看任何一张图都不会发现，互查立刻暴露。

### 6.2 质量属性提问（ATAM 风格）

已知实例（来自取证）：

- **可用性**：密码重置邮件 `Task.start` fire-and-forget——失败不重试、不告警、无持久化（运维文档 §3 自认）。生产上线前的显式风险。
- **可靠性**：`claim_first` 幂等策略下 Oban 入队失败 = 通知永久丢失（notification_subscriber 注释自认）。是"至多一次"的自觉选择，但依赖方需知情。
- **可运维性**：无生产部署 = 上线时这些假设将集中接受检验。

### 6.3 Fitness functions（可执行化的架构约束）

演进式架构思路：把"图目录完整性"变成可检查规则。候选清单（按落地成本排序）：

1. **GraphQL 面防漂移**：miniprogram 已有 `check:graphql`（codegen diff）——web 可复用同模式；
2. **signal 孤儿检查**：`signal-event-catalog.puml` 手工标注了无订阅方信号（speaker.declined、sponsorship.*）——可写脚本对比 SignalEmitter 产出类型 × SignalSubscriber patterns，孤儿需显式声明；
3. **资源目录检查**：Ash 资源全集 × `domain-model-er.puml` 实体清单 diff，新增资源未入图时提醒；
4. **枚举漂移检查**：WorkflowRun/Enrollment 等状态机枚举值 × `entity-state-machines.puml` 状态集 diff。

1 已存在、2–4 是低成本脚本（读 .puml 文本 + 读代码枚举），适合排入 CI。

### 6.4 反模式扫描（初判）

- **无** 大泥球/分布式单体迹象：域目录边界清晰（accounts/events/workflows/mcp/...），单体内聚。
- **需关注**：`update_facts_for_mcp` 的 bypass 双分支（成员 + enrolled learner）是业务规则渗入资源层 policy 的信号——规则本体已抽到 StepAuthorization 单一实现，尚可接受，但它是最接近"例外堆积"的点，新增第三分支时应考虑上移到工具层统一判定。

## 7. 行动建议（⑥层结果）

### 7.1 裁决表（2026-08-16 已裁决并执行，commit 见 git log）

| # | 事项 | 判定 | 裁决 | 执行状态 |
|---|---|---|---|---|
| R1 | enrollment/sponsorship 实体自序贯 vs 图画成引擎编排 | 图旧（有拍板：sponsorship.ex:226） | 改图 | ✅ 两图重画为「实体状态机 + 信号」，保留二期引擎化注记 |
| R2 | `Step.agent_id` 悬空引用（Agent 族无表） | 腐蚀倾向 | **删列**（用户拍板） | ✅ step.ex 删属性 + migration 20260816200000 + 测试绿 |
| R3 | platform_ops 类型枚举无驱动 | 悬空 | **删枚举**（用户拍板） | ✅ @type_values 5 值 + migration 清数据 + 测试改 5 值含拒绝旧值 |
| R4 | learning 绕 Engine（协议非 DAG） | 图漏 | 补图 | ✅ 新增 `workflow-learning.puml`（第三种形态完整呈现） |
| R5 | 四组 POC 词汇悬空 | 图旧（POC 当产品） | 移除/标注 | ✅ 4 张 L3 图清理；F8 在 REVIEW-FINDINGS 更正关闭 |
| R6 | WorkflowRun :expired + F2 已闭环 | 图旧 | 更新 | ✅ 7 态 + EXPIRED 转移；F2/F7/F1/F12 关闭 |
| R7 | 枚举族漂移 | 图旧 | 更新 | ✅ entity-state-machines / confirm-flow / L1 两图对齐码枚举 |
| R8 | F4 支付状态未预留 | 悬空（v1 有意） | 基准外 | ✅ 已回写（2026-08-17）：payments 闭环合入 develop（#181/#184/#187）——Enrollment 6 态含 payment_pending、Order 7 态、webhook 面、Provider 三 adapter；图侧同步见分支 docs/diagram-sync-payment-course。注：支付落在 **Enrollment**（缴费闭环 plan 024），F4 原设想插在 Sponsorship 状态机—— sponsorship 仍 v1 不收款 |
| R9 | D12 绝对化表述 | 图旧（弱） | 更新 | ✅ architecture-overview 加例外清单 |
| R10 | 邮件 fire-and-forget + claim_first 至多一次 | 质量属性风险 | 上线前裁决 | ⏸ 未裁决（运维文档 §3） |

ER 图 PendingOperation/ToolCallLog 枚举与字段名同步。

> **2026-08-17 增量对账**（基准 develop@7c8cadb，payments #181/#184/#187 + course-issue #183/#186 合入后）：
> 新增漂移已同步——Enrollment 6 态（+payment_pending，F4 兑现）、payments 域（Order/WebhookEvent/PriceTier）、
> LearningRecord、MCP 工具 8→12、webhook 第五 API 面；同步分支 docs/diagram-sync-payment-course。

### 7.2 还账清单（图侧，低成本）

1. `key-routing-isolation.puml`：幂等承载表述改为「Postgres（唯一索引）；Redis 备选未接线」；
2. `architecture-overview.puml`：补 miniprogram 渠道与 MCP server 面，或加指向 `container-topology.puml` 的引用；
3. `workflow-*.puml` 系列：按 §5.3 取证结果决定逐张更新或加"实现现状见 DRIFT-REPORT §5.3"引用注记。

### 7.3 防漂移流程（沉淀）

- **锚点约定**（已有）：每张图头注释「事实来源」行是唯一锚点，改码/改图先查对方；
- **新增约定**：动到对照物之一的 PR，description 勾一项「是否影响某张图」清单（把图当测试用例对待）；
- **CI 化**（§6.3 的 2–4 项）：孤儿 signal / 资源目录 / 枚举漂移三个脚本，warning 起步，稳定后升级 fail；
- **节奏**：每次里程碑（或每 N 周）跑一次完整对照，报告增量更新本文件 §5。

## 8. 复用指南：别的项目怎么套（分享 takeaways）

1. **从理论并集开始，但以裁剪收尾**——判"不适用"并写理由，和补图同样重要；
2. **新图取证 codebase、老图锚定设计文档**——两个快照的差集就是漂移清单，不需要考古每张老图；
3. **四态判定语言**（一致/图旧/腐蚀/悬空）把"架构腐了"的情绪问题变成可拍板的工程问题；
4. **图是测试用例**：视图间一致性规则 + fitness function 脚本，让图进入 CI 而不是躺在 docs；
5. **漂移不可怕，不裁决才可怕**：每次对照的产出必须是裁决表，而不是更厚的报告。

---

*取证方法：三路并行 scout（L1 领域模型 / L2 工作流 / L3 机制+L0 复核），每条结论要求文件路径级证据；本报告只汇总判定与建议，原始取证不重复粘贴。*
