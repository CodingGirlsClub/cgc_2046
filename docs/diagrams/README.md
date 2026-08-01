# CGC 平台架构图资产索引（L0–L4）

> 本目录由**架构可视化工程师**（worker_8984c7a9）维护。
> 所有图均为 PlantUML 源文件（`.puml`），事实来源为 `docs/00-CGC平台设计总纲.md` 与 `docs/01-定稿设计/` 下各详细设计文档。
> 每张图头部注释均标注了对应的事实来源章节，修订文档时请同步更新图。

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

## 二、图索引

### L0 — 系统全景（2 张）

| 文件 | 内容 | 对应文档 |
|------|------|----------|
| `system-context.puml` | 系统上下文：CGC 平台与外部角色/系统（用户、OpenClacky、连接器、支付/邮件等）的边界 | 总纲 §1 系统边界 |
| `architecture-overview.puml` | 分层架构总览：接入层（Web/Agent/OpenClacky）→ 编排层（Jido Workflow）→ 领域层 → 引擎层，Signal 门控机制 | 总纲 §2 分层架构 |

### L1 — 领域模型（2 张）

| 文件 | 内容 | 对应文档 |
|------|------|----------|
| `domain-model-er.puml` | 领域模型 ER：全局资源（User/Identity/Token/Workspace 不按租户隔离）与租户内实体（Event/Course/Enrollment/Sponsorship/Invitation 等）及关系、唯一约束 | 领域模型定稿 §5.2 ER 关系 |
| `domain-model-class.puml` | 领域模型类图：核心聚合根（Event/Course/WorkflowDefinition/WorkflowRun/SignalFact 等）、关键枚举与状态 | 领域模型定稿 §5 类模型 |

### L2 — 业务工作流（5 张）

| 文件 | 内容 | 对应文档 |
|------|------|----------|
| `workflow-enrollment.puml` | 报名 workflow：三段式（申请段 S0–S6、确认段 S7–S9、收尾段 S10–S12），open/invite_only 分支，request 策略走审批 | 报名workflow详细设计 §4/§5 |
| `workflow-sponsorship.puml` | 赞助 workflow：两级赞助（Event/Course 级），审批两段式同构，审批与权益激活 | 赞助workflow详细设计 §4/§5 |
| `workflow-invitation.puml` | 邀请 workflow：逐人 token 一次性邀请，接受/婉拒双分支，S7 校验批次 | 邀请workflow详细设计 §4/§5 |
| `workflow-research.puml` | 教研 workflow：三段式模板（教研产出段 S0–S6、现场辅导段 S7–S9 循环、收尾段 S10–S12），D-A2 定义一次多实例 | 教研workflow详细设计 §4/§5 |
| `workflow-run-state.puml` | WorkflowRun 状态机：pending→running→waiting→succeeded/failed/cancelled，waiting 挂起与 Signal 恢复 | 总纲 §3.2 + 引擎验证 POC-2 |
| `entity-state-machines.puml` | 业务实体状态机汇总：Enrollment/Sponsorship/SpeakerInvitation/WorkflowDefinition/InviteBatch/ResearchOutput | 各详细设计 §5.2 |

### L3 — 引擎/机制（5 张）

| 文件 | 内容 | 对应文档 |
|------|------|----------|
| `signal-join-strategies.puml` | 双信号 join 策略：Workflow 原生 join 路径（v1 主路径）/ 审批两段式规避（业务异步审批需要 + Agent 层缺陷未修复前的架构层规避）/ fan-in 修复（F1 已定位：jido_runic ran_nodes 过滤缺陷，waiting 占位不应记 ran_nodes，修复 POC 已验证 PASS，Agent 层标准写法 = 官方 Coordinator fan-in） | 报名/赞助详细设计 §6 + POC-2 §3.2/§3.3/§3.4 |
| `confirm-flow.puml` | 确认段（S7 创建）时序：`pending` 恢复 → A3 原子扣名额 → 发确认 | 报名workflow详细设计 §5 |
| `hibernate-thaw.puml` | WorkflowRun 挂起/唤醒时序：hibernate 持久化 → 外部事件 → thaw 恢复 | 总纲 §3.3 + POC-2 G1 |
| `key-routing-isolation.puml` | 幂等三层与路由隔离：request_id + 业务唯一索引 + signal idempotency_key，承载 Postgres/Redis | 报名/赞助详细设计 §6.4 + POC-2 |
| `template-parameterization.puml` | workflow 模板参数化：D-A2 定义一次、多 Event 复用，参数注入与实例隔离 | 教研workflow详细设计 §7 |

### L4 — 用户旅程（1 张）

| 文件 | 内容 | 对应文档 |
|------|------|----------|
| `user-journeys.puml` | 8 类角色旅程总览：J0 BYO 三步、报名、赞助、邀请、教研、学习、运营后台 | 用户旅程与Web功能清单 |

## 三、图与文档的同步约定

- 每张图头部注释里的 `事实来源` 行是**唯一事实锚点**；改文档先看图，改图先查文档。
- L2/L3 图中标注的 `（二期）` / `（待 v1 补测试）` 等标记，对应 `docs/03-决策记录/开放问题决策清单.md` 与 `docs/04-引擎验证/poc-验证报告.md` 中的未决/遗留项。
- 画图过程中发现的文档矛盾、缺口与建议，见同目录 [REVIEW-FINDINGS.md](./REVIEW-FINDINGS.md)。
