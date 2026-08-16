# CGC 平台架构图资产索引（L0–L4）

> 本目录由**架构可视化工程师**（worker_8984c7a9）维护。
> 所有图均为 PlantUML 源文件（`.puml`），事实来源为 `docs/00-CGC平台设计总纲.md` 与 `docs/01-定稿设计/` 下各详细设计文档。
> 每张图头部注释均标注了对应的事实来源章节，修订文档时请同步更新图。
>
> **2026-08 修订（分类体系升级）**：按社区最佳实践（C4 model / arc42 / 4+1 视图 / 事件驱动架构文档实践）
> 对标原 L0–L4 分类，补齐缺失类别（见「二、分类体系与业界实践对照」）。本轮只建分类骨架，
> ⏳ 待补图暂不绘制；骨架用途是后续「codebase ↔ 图」**架构漂移对照**的基准框架。

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
| 容器（运行时单元）拓扑 | C4 L2 / arc42 §5 | L0 `container-topology` | ⏳ 待补 |
| 逻辑分层 / 构建块 | arc42 §5 | L0 `architecture-overview` | ✅ |
| 部署视图 | C4 Deployment / 4+1 Physical / arc42 §8 | L0 `deployment-view` | ⏳ 待补 |
| 接口契约 | arc42 §3.2 | L0 `api-contracts` | ⏳ 待补 |
| 领域模型（结构） | 4+1 Logical / C4 L4 | L1 `domain-model-er` / `domain-model-class` | ✅ |
| 领域事件 / 消息目录 | 事件驱动文档实践（EventCatalog 等） | L1 `signal-event-catalog` | ⏳ 待补 |
| 业务流程 / 场景 | 4+1 Scenarios / arc42 §6 | L2 `workflow-*` | ✅ |
| 状态机 | UML 行为图 | L2 `workflow-run-state` / `entity-state-machines` | ✅ |
| 运行时交互（时序） | C4 Dynamic / arc42 §6 | L3.2 `confirm-flow` / `hibernate-thaw` | ✅ 已有实例 |
| 横切概念 | arc42 §7 | L3.3 `key-routing-isolation`（幂等）✅；鉴权 / 租户隔离 / 审计 ⏳ | ◐ 部分 |
| 用户旅程 | 4+1 Scenarios（用户视角） | L4 `user-journeys` | ✅ |
| 决策记录 | arc42 §9 | `docs/adr/` + `docs/03-决策记录/`（文字资产，不图形化） | ✅ |
| 风险 / 质量 | arc42 §10 / §11 | `REVIEW-FINDINGS.md` + 开放问题决策清单（文字资产） | ✅ |
| 组织级全景 | C4 System Landscape | 不适用（单产品单团队） | — |
| 组件级 | C4 L3 Component | 由 L3 机制图承担，当前项目规模不单列 | — |

**本次补齐的缺失类别**（5 张待补图 + 1 个显式化子类），及各自要回答的问题：

| 待补项 | 类别出处 | 回答的问题 | 事实来源候选 |
|---|---|---|---|
| `container-topology.puml` | C4 Container | 平台由哪些**运行时单元**组成（backend / web / miniprogram / openclacky-ext / Postgres / Redis+Oban / 邮件、支付等外部依赖），各自职责、技术选型、相互协议 | codebase 顶层结构 + 运维文档 |
| `deployment-view.puml` | C4 Deployment / 4+1 Physical | 各单元部署在哪个节点与环境（prod / staging / dev），CD 流水线与配置注入 | `docs/运维/邮件与CD环境注入.md` |
| `api-contracts.puml` | arc42 §3.2 | 平台对外暴露哪些 API 面：GraphQL 面与 MCP 工具面（工具清单、确认流）、各面凭证与鉴权差异（cookie JWT vs Bearer token） | `backend/priv/graphql/schema.graphql` + `Cgc2046.Mcp.Server` |
| `signal-event-catalog.puml` | 事件驱动文档实践 | signal 全目录：类型、生产者、消费者、幂等键、驱动哪个 workflow step | 各 workflow 详细设计 §4 + codebase signal 定义 |
| `auth-tenant-isolation.puml` | arc42 §7 横切概念 | 凭证模型全景（网站 JWT / MCP 连接 token / 邀请 token / 批次码）、多租户隔离边界、审计日志（ToolCallLog / AdminActionLog） | 领域模型定稿 + D6 / D13 决策 |
| L3.2 子类显式化 | C4 Dynamic / arc42 §6 | 每个关键场景一张时序图；已有确认流、挂起唤醒两例，报名全程 / 支付 / 邀请接受等场景按需增补 | 各详细设计 §5 |

> **已知漂移信号**（对照 codebase 顶层即得，先记录、后处理）：
> `miniprogram/` 与 `openclacky-ext/` 两个顶层运行时单元在现有 L0 图中无任何对应；
> MCP 工具面（anubis_mcp streamable HTTP，D6 / D7）在 `architecture-overview` 中未见独立呈现。
> 这正是 `container-topology` / `api-contracts` 两类的价值所在——补图时一并裁决。

## 三、图索引

### L0 — 系统全景与边界（2 ✅ + 3 ⏳）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `system-context.puml` | ✅ | 系统上下文：CGC 平台与外部角色/系统（用户、OpenClacky、连接器、支付/邮件等）的边界 | 总纲 §1 系统边界 |
| `architecture-overview.puml` | ✅ | 分层架构总览：接入层（Web/Agent/OpenClacky）→ 编排层（Jido Workflow）→ 领域层 → 引擎层，Signal 门控机制 | 总纲 §2 分层架构 |
| `container-topology.puml` | ⏳ 待补 | 容器拓扑：运行时单元全景（见「二」待补表） | 待定（codebase 顶层 + 运维文档） |
| `deployment-view.puml` | ⏳ 待补 | 部署视图：单元 × 节点 × 环境映射（见「二」待补表） | 待定（docs/运维/） |
| `api-contracts.puml` | ⏳ 待补 | 接口契约：GraphQL 面与 MCP 工具面（见「二」待补表） | 待定（schema.graphql + Mcp.Server） |

### L1 — 领域模型（2 ✅ + 1 ⏳）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `domain-model-er.puml` | ✅ | 领域模型 ER：全局资源（User/Identity/Token/Workspace 不按租户隔离）与租户内实体（Event/Course/Enrollment/Sponsorship/Invitation 等）及关系、唯一约束 | 领域模型定稿 §5.2 ER 关系 |
| `domain-model-class.puml` | ✅ | 领域模型类图：核心聚合根（Event/Course/WorkflowDefinition/WorkflowRun/SignalFact 等）、关键枚举与状态 | 领域模型定稿 §5 类模型 |
| `signal-event-catalog.puml` | ⏳ 待补 | 领域事件/信号目录：类型、生产者、消费者、幂等键、驱动的 step（见「二」待补表） | 待定（详细设计 §4 + codebase） |

### L2 — 业务工作流（6 张）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `workflow-enrollment.puml` | ✅ | 报名 workflow：三段式（申请段 S0–S6、确认段 S7–S9、收尾段 S10–S12），open/invite_only 分支，request 策略走审批 | 报名workflow详细设计 §4/§5 |
| `workflow-sponsorship.puml` | ✅ | 赞助 workflow：两级赞助（Event/Course 级），审批两段式同构，审批与权益激活 | 赞助workflow详细设计 §4/§5 |
| `workflow-invitation.puml` | ✅ | 邀请 workflow：逐人 token 一次性邀请，接受/婉拒双分支，S7 校验批次 | 邀请workflow详细设计 §4/§5 |
| `workflow-research.puml` | ✅ | 教研 workflow：三段式模板（教研产出段 S0–S6、现场辅导段 S7–S9 循环、收尾段 S10–S12），D-A2 定义一次多实例 | 教研workflow详细设计 §4/§5 |
| `workflow-run-state.puml` | ✅ | WorkflowRun 状态机：pending→running→waiting→succeeded/failed/cancelled，waiting 挂起与 Signal 恢复 | 总纲 §3.2 + 引擎验证 POC-2 |
| `entity-state-machines.puml` | ✅ | 业务实体状态机汇总：Enrollment/Sponsorship/SpeakerInvitation/WorkflowDefinition/InviteBatch/ResearchOutput | 各详细设计 §5.2 |

### L3 — 引擎与横切机制（5 ✅ + 1 ⏳）

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
| `auth-tenant-isolation.puml` | ⏳ 待补 | 凭证模型全景、多租户隔离、审计日志（见「二」待补表） | 待定（领域模型定稿 + D6/D13） |

### L4 — 用户旅程（1 张）

| 文件 | 状态 | 内容 | 对应文档 |
|------|------|------|----------|
| `user-journeys.puml` | ✅ | 8 类角色旅程总览：J0 BYO 三步、报名、赞助、邀请、教研、学习、运营后台 | 用户旅程与Web功能清单 |

## 四、图与文档的同步约定

- 每张图头部注释里的 `事实来源` 行是**唯一事实锚点**；改文档先看图，改图先查文档。
- L2/L3 图中标注的 `（二期）` / `（待 v1 补测试）` 等标记，对应 `docs/03-决策记录/开放问题决策清单.md` 与 `docs/04-引擎验证/poc-验证报告.md` 中的未决/遗留项。
- 画图过程中发现的文档矛盾、缺口与建议，见同目录 [REVIEW-FINDINGS.md](./REVIEW-FINDINGS.md)。
- **架构漂移对照（本分类体系的用途）**：按层拿 codebase 对照——L0 对照顶层运行时单元与部署配置、L1 对照 Ash 资源与 signal 定义、L2/L3 对照 workflow 与机制实现，识别「代码走向 vs 设计原图」的偏离；⏳ 待补图补齐前，对照发现先以「已知漂移信号」形式记录（见「二」）。
- **体系外文字资产**（与本目录互为引用，不图形化）：架构决策 `docs/adr/` 与 `docs/03-决策记录/`；风险与遗留 `REVIEW-FINDINGS.md`；领域术语 `CONTEXT.md`。
