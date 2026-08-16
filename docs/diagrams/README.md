# CGC 平台架构图资产索引（L0–L4）

> 本目录由**架构可视化工程师**（worker_8984c7a9）维护。
> 所有图均为 PlantUML 源文件（`.puml`），事实来源为 `docs/00-CGC平台设计总纲.md` 与 `docs/01-定稿设计/` 下各详细设计文档。
> 每张图头部注释均标注了对应的事实来源章节，修订文档时请同步更新图。
>
> **2026-08 修订（分类体系升级）**：按社区最佳实践（C4 model / arc42 / 4+1 视图 / 事件驱动架构文档实践）
> 对标原 L0–L4 分类，补齐缺失类别（见「二、分类体系与业界实践对照」）。
> **五张待补图已全部绘制**（container-topology / deployment-view / api-contracts /
> signal-event-catalog / auth-tenant-isolation，均以 codebase 现状为事实来源）；
> 该体系作为后续「codebase ↔ 图」**架构漂移对照**的基准框架。

## 一、怎么打开 / 渲染这些图

- **本地渲染**（需安装 PlantUML，且要求 1.2026.6+ 版本，本机已验证）：
  ```bash
  # SVG 输出（推荐，可无限缩放）
  plantuml -tsvg architecture-overview.puml
  # PNG 输出
  plantuml -tpng architecture-overview.puml
  ```
- **Zed / VS Code**：安装 PlantUML 插件后可直接预览 `.puml` 文件。
- **在线预览**：把 `.puml` 内容粘贴到 [PlantUML 在线服务器](https://www.plantuml.com/plantuml) 即可。

> ⚠️ 已知语法约束（本机 PlantUML 1.2026.6 验证）：
> - **不要写 `sequenceDiagram` 关键字** —— 该版本会误判为 sequence 图并报错；直接写 `A->>B: msg` 自动检测即可。
> - **component 场景用 `package` + `rectangle`**，不要用 `partition` + `rectangle`（会误判为 activity）。
> - **activity 图用 `note right` / `note`**，不要用 `note bottom`。
> - **participant 别名含空格/括号时加引号**：`participant "用户 OpenClacky（Agent）" as A`。

## 二、分类体系与业界实践对照

业界用图完整描述一个软件项目时的标准类别（取 C4 model、arc42 模板、4+1 视图、事件驱动架构文档实践之并集），与本项目分层对照：

| 业界类别 | 出处 | 本项目对应 | 状态 |
|---|---|---|---|
| 系统上下文 | C4 L1 / arc42 §3 | L0 `system-context` | ✅ |
| 容器（运行时单元）拓扑 | C4 L2 / arc42 §5 | L0 `container-topology` | ✅ |
| 逻辑分层 / 构建块 | arc42 §5 | L0 `architecture-overview` | ✅ |
| 部署视图 | C4 Deployment / 4+1 Physical / arc42 §8 | L0 `deployment-view` | ✅ |
| 接口契约 | arc42 §3.2 | L0 `api-contracts` | ✅ |
| 领域模型（结构） | 4+1 Logical / C4 L4 | L1 `domain-model-er` / `domain-model-class` | ✅ |
| 领域事件 / 消息目录 | 事件驱动文档实践（EventCatalog 等） | L1 `signal-event-catalog` | ✅ |
| 业务流程 / 场景 | 4+1 Scenarios / arc42 §6 | L2 `workflow-*` | ✅ |
| 状态机 | UML 行为图 | L2 `workflow-run-state` / `entity-state-machines` | ✅ |
| 运行时交互（时序） | C4 Dynamic / arc42 §6 | L3.2 `confirm-flow` / `hibernate-thaw` | ✅ 已有实例 |
| 横切概念 | arc42 §7 | L3.3 `key-routing-isolation`（幂等）+ `auth-tenant-isolation`（凭证/租户/审计） | ✅ |
| 用户旅程 | 4+1 Scenarios（用户视角） | L4 `user-journeys` | ✅ |
| 决策记录 | arc42 §9 | `docs/adr/` + `docs/03-决策记录/`（文字资产，不图形化） | ✅ |
| 风险 / 质量 | arc42 §10 / §11 | `REVIEW-FINDINGS.md` + 开放问题决策清单（文字资产） | ✅ |
| 组织级全景 | C4 System Landscape | 不适用（单产品单团队） | — |
| 组件级 | C4 L3 Component | 由 L3 机制图承担，当前项目规模不单列 | — |

**已补齐的缺失类别**（5 张新图 + 1 个显式化子类），绘制时的事实来源与回答的问题：

| 图 | 类别出处 | 回答的问题 | 实际事实来源 |
|---|---|---|---|
| `container-topology.puml` | C4 Container | 平台由哪些**运行时单元**组成，各自职责、技术选型、相互协议 | 仓库顶层结构 + config.exs（Oban PG-backed）+ router.ex 挂载 + next.config.ts |
| `deployment-view.puml` | C4 Deployment / 4+1 Physical | 各单元部署在哪个节点与环境，CD 流水线与配置注入 | `docs/运维/邮件与CD环境注入.md`（含「无部署信号」现状 + prod 注入契约）+ ci.yml |
| `api-contracts.puml` | arc42 §3.2 | 四个 API 面：GraphQL（Query 36 / Mutation 60+ 字段）、MCP 8 工具、AshAdmin /ops、dev /dev/mailbox；各面凭证差异 | router.ex + schema.graphql + `Cgc2046.Mcp.Server` |
| `signal-event-catalog.puml` | 事件驱动文档实践 | signal 全目录：17 种类型 × 生产者 × 六订阅方 × 幂等四策略 | `signal_emitter.ex` / `signal_subscriber.ex` / 六订阅方模块 / `signal_idempotency.ex` |
| `auth-tenant-isolation.puml` | arc42 §7 横切概念 | 四种凭证模型、全局/租户资源边界、四条审计链路 | `mcp/token.ex` / `tool_call_log.ex` / `policies/actor_is_enrolled_learner.ex` + D5/D6/D9/D12/D13 |
| L3.2 子类显式化 | C4 Dynamic / arc42 §6 | 每个关键场景一张时序图；已有确认流、挂起唤醒两例，报名全程 / 支付 / 邀请接受等场景按需增补 | 各详细设计 §5 |

> **漂移信号裁决记录**（原三例，本轮补图时处理）：
> - `miniprogram/` 与 `openclacky-ext/` 顶层单元 → 已入 `container-topology`（小程序多端 + 扩展属用户侧交付物，均非原 L0 设计图的覆盖范围）；
> - MCP 工具面未见独立呈现 → 已入 `container-topology`（/mcp 容器）+ `api-contracts`（面 2，8 工具全清单）。
> 新增漂移发现（来自本轮 codebase 取证，待下一步架构对照时处理）：
> - **Redis 幂等承载未实现**：`key-routing-isolation.puml` 声称「幂等三层承载 Postgres/Redis」，但 config 无 Redix、`signal_idempotency` 落 Postgres——Redis 仅文档备选；
> - **无生产部署**：`deployment-view` 如实呈现「无 vercel/fly/docker 配置」现状，与原图隐含的部署预期存在差距；
> - **信号架构演进**：实际实现是 Phoenix PubSub 进程内总线 + Oban 重投 + 六订阅方幂等四策略（PR-B 深化），比原 L3 图（signal 直接 feed 引擎）更丰富。
> **2026-08-17 增量同步**（基准 develop@7c8cadb：payments #181/#184/#187 + course-issue #183/#186 合入）：
> 10 张图更新——payments 全域（Order/WebhookEvent/Provider 三 adapter/webhook 第五面/5 worker/七订阅方）、
> Enrollment 6 态（payment_pending，F4 兑现且落报名侧）、course-issue 闭环（LearningRecord/ResearchOutput 活文档/
> MCP 工具 8→12/LearnerAuthorization）。详见 DRIFT-REPORT §7.1 R8 与 REVIEW-FINDINGS F4。

## 三、图索引

### L0 — 系统全景与边界（5 张）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `system-context.puml` | ✅ | 系统上下文：CGC 平台与外部角色/系统（用户、OpenClacky、微信支付/支付宝缴费渠道、SendCloud 邮件等）的边界 | 总纲 §1 + 2026-08-17 支付渠道 |
| `architecture-overview.puml` | ✅ | 分层架构总览：接入层（Web/Agent/OpenClacky）→ 编排层（Jido Workflow）→ 领域层 → 引擎层，Signal 门控机制 | 总纲 §2 分层架构 |
| `container-topology.puml` | ✅ 新 | 容器拓扑：web/miniprogram/backend（GraphQL+MCP+引擎+Oban 三队列+邮件+payments 域+webhook 入口）/Postgres + 用户侧 openclacky-ext + 微信/支付宝外部系统 | codebase 顶层 + config.exs + router.ex |
| `deployment-view.puml` | ✅ 新 | 部署视图：GitHub CI + 开发机拓扑 + 生产目标（如实呈现「无部署信号」现状 + SendCloud 五值注入契约与 fail-fast） | docs/运维/邮件与CD环境注入.md |
| `api-contracts.puml` | ✅ 新 | 接口契约：五个面（GraphQL Q50/M63 / MCP 12 工具 / AshAdmin /ops / dev mailbox / **payments webhook 渠道回调·无 actor 验签**）× 凭证 × 审计 | router.ex + schema.graphql + Mcp.Server |

### L1 — 领域模型（3 张）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `domain-model-er.puml` | ✅ | 领域模型 ER：全局资源（User/Workspace/…+WebhookEvent）与租户内实体（+payments 区 Order、learning 区 LearningRecord/ResearchOutput）及关系、唯一约束 | 领域模型定稿 §5.2 + payments/learning 模块 |
| `domain-model-class.puml` | ✅ | 领域模型类图：核心聚合根（+Order/ResearchOutput/LearningRecord context）、关键枚举（Enrollment 6 态/Order 7 态） | 领域模型定稿 §5 + payments/learning 模块 |
| `signal-event-catalog.puml` | ✅ 新 | 信号目录：18 种类型（+order.paid）× 生产者 × **七订阅方**（+EventCancelRefundWorker）× 幂等四策略；payments 状态迁移不走总线（webhook+worker 直推） | signal_emitter/signals_subscriber/订阅方模块 |

### L2 — 业务工作流（7 张；2026-08-16 漂移对账重绘）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `workflow-enrollment.puml` | ✅ 重绘 | 报名（实体自序贯 + **缴费闭环**）：免费/收费分叉（payment_pending）、Order→渠道支付→webhook 落账→settlement 确认、waive_payment 免缴、过期三联动、退款族 worker | enrollment.ex + payments/order.ex + workers |
| `workflow-sponsorship.puml` | ✅ 重绘 | 赞助（实体自序贯，R1）：approve 条件 UPDATE + SponsorshipDelivery 履约物化；**仍不收款**（缴费闭环落报名侧，见 F4 闭环注） | sponsorship.ex + DRIFT-REPORT §5.3 |
| `workflow-invitation.puml` | ✅ | 邀请 workflow：逐人 token 一次性邀请，接受/婉拒双分支（图=码一致，未改） | 邀请workflow详细设计 §4/§5 |
| `workflow-research.puml` | ✅ | 教研 workflow：三段式模板，D-A2 定义一次多实例（图=码一致，未改） | 教研workflow详细设计 §4/§5 |
| `workflow-learning.puml` | ✅ 新 | 学习 workflow（第三种形态）+ **course-issue 闭环**：issue 级 LearningRecord 读写四工具、LearnerAuthorization 三层授权、all_issues_done? 完成判定、ResearchOutput 活文档 | learning_record.ex + mcp/tools + research_output.ex |
| `workflow-run-state.puml` | ✅ 重绘 | WorkflowRun 状态机 7 态（+expired）；WAITING→EXPIRED 由 ApprovalExpiryWorker 驱动（F2 闭环） | workflow_run.ex + approval_expiry_worker.ex |
| `entity-state-machines.puml` | ✅ 重绘 | 业务实体状态机：Enrollment 6 态（+payment_pending 缴费路径）、**Order 7 态**（新，退款/批量退款分支）、Sponsorship 5 态、SPI 4 态、InviteBatch 2 态；ResearchOutput=活文档单态 | 各资源 status attribute |

### L3 — 引擎与横切机制（6 张）

**3.1 引擎机制**

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `signal-join-strategies.puml` | ✅ | 双信号 join 策略：Workflow 原生 join 路径（v1 主路径）/ 审批两段式规避（业务异步审批需要 + Agent 层缺陷未修复前的架构层规避）/ fan-in 修复（F1 已定位：jido_runic ran_nodes 过滤缺陷，waiting 占位不应记 ran_nodes，修复 POC 已验证 PASS，Agent 层标准写法 = 官方 Coordinator fan-in） | 报名/赞助详细设计 §6 + POC-2 §3.2/§3.3/§3.4 |
| `template-parameterization.puml` | ✅ | workflow 模板参数化：D-A2 定义一次、多 Event 复用，参数注入与实例隔离 | 教研workflow详细设计 §7 |

**3.2 运行时交互（时序；C4 Dynamic / arc42 运行时视图）**

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `confirm-flow.puml` | ✅ | 确认段（S7 创建）时序：`pending` 恢复 → A3 原子扣名额 → 发确认 | 报名workflow详细设计 §5 |
| `hibernate-thaw.puml` | ✅ | WorkflowRun 挂起/唤醒时序：hibernate 持久化 → 外部事件 → thaw 恢复 | 总纲 §3.3 + POC-2 G1 |

**3.3 横切概念**

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `key-routing-isolation.puml` | ✅ | 幂等三层与路由隔离：request_id + 业务唯一索引 + signal idempotency_key，承载 Postgres/Redis | 报名/赞助详细设计 §6.4 + POC-2 |
| `auth-tenant-isolation.puml` | ✅ 新 | 横切概念：四种凭证模型 + **第五面 payments webhook（无 actor 渠道验签）**、全局 vs 租户资源（+Order/WebhookEvent/LearningRecord）、审计链路（+AdminActionLog waive/退款留痕、order.paid） | mcp/token.ex + policies + webhook controller + D5/D6/D9/D12/D13 |

### L4 — 用户旅程（1 张）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `user-journeys.puml` | ✅ | 8 类角色旅程总览：J0 BYO 三步、报名、赞助、邀请、教研、学习、运营后台 | 用户旅程与Web功能清单 |

## 四、图与文档的同步约定

- 每张图头部注释里的 `事实来源` 行是**唯一事实锚点**；改文档先看图，改图先查文档。
- L2/L3 图中标注的 `（二期）` / `（待 v1 补测试）` 等标记，对应 `docs/03-决策记录/开放问题决策清单.md` 与 `docs/04-引擎验证/poc-验证报告.md` 中的未决/遗留项。
- 画图过程中发现的文档矛盾、缺口与建议，见同目录 [REVIEW-FINDINGS.md](./REVIEW-FINDINGS.md)。
- **架构漂移对照（本分类体系的用途）**：按层拿 codebase 对照——L0 对照顶层运行时单元与部署配置、L1 对照 Ash 资源与 signal 定义、L2/L3 对照 workflow 与机制实现，识别「代码走向 vs 设计原图」的偏离；首批漂移裁决与新发现见「二」的「漂移信号裁决记录」。
- **体系外文字资产**（与本目录互为引用，不图形化）：架构决策 `docs/adr/` 与 `docs/03-决策记录/`；风险与遗留 `REVIEW-FINDINGS.md`；领域术语 `CONTEXT.md`。
- **漂移对照报告**：完整对照结果（四态判定 + 裁决表 + 防漂移流程）见 [DRIFT-REPORT.md](./DRIFT-REPORT.md)；三份取证底稿在 [DRIFT-EVIDENCE/](./DRIFT-EVIDENCE/)（L1 领域模型 / L2 工作流 / L3 引擎机制+L0 复核，文件路径级证据）。
