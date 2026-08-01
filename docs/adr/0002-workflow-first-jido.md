# ADR-0002: workflow-first + Jido 架构

> 日期：2026-08-01 ｜ 状态：**已接受（Accepted）** ｜ 决策者：用户（方伯）+ Leader + Jido/Workflow架构研究员（worker_4cfa7aa2）+ 领域建模工程师（worker_f150e10b）
> 关联：ADR-0001（网站作为 MCP server 的 BYO 架构）、docs/03-决策记录/grill-决策记录-2026-08-01.md（D1-D14）、docs/04-引擎验证/workflow-engine-ddd-design.md

---

## 背景（Context）

- 平台已确认 BYO 架构（ADR-0001）：网站不做 AI 执行，暴露 MCP server 被用户 OpenClacky 调用。
- 用户与 Jido/Workflow 架构研究员调研 Jido 生态后共识：平台业务（报名、开课、教研、赞助、邀请）本质是多步编排，需要**一等公民的 workflow 引擎**，而不是把"流程"当作简单的顺序 Step 列表。
- 选型：Jido 生态（Action/Signal/Directive/Strategy/Agent）+ jido_runic（DAG workflow 桥接）+ ash_jido（Ash Resource action → Jido Action 编译期桥接）。
- 核心张力：网站侧跑 workflow 引擎是否会与 BYO（D1：网站不自行实现 AI Agent）矛盾？→ 结论：**不矛盾**，引擎只做确定性编排，不跑 LLM（详见 §决策 7）。

## 决策（Decision）

> 与 CONTEXT.md 的 D-A 系列编号对应（D-A1–D-A7，workflow-first 追加决策）。

| # | 决策 | 本 ADR 对应 |
|---|---|---|
| D-A1 | WorkflowDefinition（蓝图）+ WorkflowRun（执行实例）为核心模型；引擎选型 Jido | 决策 1/2/3/8 |
| D-A2 | WorkflowDefinition 带版本管理（改定义不影响已开始 run） | 决策 1 |
| D-A3 | Event/Course 挂 Workspace（Event 场地形态 / Course 线上课程）；Sponsorship 两级（Event+Workspace）；SpeakerInvitation Event 级；Workspace 创建两级入口 | 领域模型定稿 §5.1 |
| D-A4 | Enrollment 归活动 context，由报名 workflow 同步调 `create_enrollment` Action 创建；不自动成为 Workspace 成员 | 决策 5 |
| D-A5 | 每 Workspace = 一个 partition；审计 context 数据源 = Thread journal | 决策 6/7 |
| D-A6 | 同步写走 Action（8 成）、衍生/通知走 Signal 异步（2 成） | 决策 5 |
| D-A7 | 连接器扩展自动配置 mcp.json（取代 D13 手动粘贴） | 不涉及（onboarding 侧） |

1. **核心 aggregate = WorkflowDefinition + WorkflowRun（引擎 context）**
   - WorkflowDefinition = DAG 蓝图（Runic.Workflow 数据流 + 元数据 id/name/type/version/输入 schema/节点定义），带版本管理；改定义不影响已开始 run。
   - WorkflowRun = 执行实例：状态机 `pending → running → waiting（人等信号）→ succeeded/failed/cancelled`；持输入快照/产物 facts/signal 日志；归属 partition。
2. **Step 四分类**：① 自动（Jido Action）；② 人工（SignalMatch 门控等待外部信号）；③ 门控/分支；④ 子 workflow（嵌套 DAG）。
3. **人工步骤模式：workflow 内部等待为主（不拆多段）**：执行到人工节点 → waiting 挂起 → 人发 Signal → SignalMatch 放行 → 恢复；长等待 hibernate/thaw（waiting 落 checkpoint 休眠，信号到达 thaw 恢复）；拆多段仅未来按需，v1 由子 workflow 覆盖"相对独立段"。
4. **跨 context 解耦：依赖方向恒为 workflow → 业务 Action 接口**：业务 context 反向只发信号、不调引擎；ash_jido 编译期把 Ash Resource action 生成 Jido Action（context 需 domain/actor/tenant）。
5. **同步 vs 异步（8:2）**：核心写走同步 Ash Action（强一致，如报名 workflow 创建 Enrollment，保证名额/唯一性不变量）；衍生副作用/跨 context 通知走 Signal 异步（最终一致，如 enrollment.completed → 赞助权益更新、通知志愿者、触发学习 workflow）。
6. **多租户 = Jido partition**：每个 Workspace = 一个 partition（registry identity、persistence、lineage、telemetry 隔离）；WorkflowRun 归属 partition。
7. **审计 context 数据源 = Jido Storage Thread journal**：append-only + Checkpoint + Introspection 溯源链；AgentRun/ToolCallLog 概念对应关系保留并说明（ToolCallLog = MCP 接入审计，Thread journal = 引擎事件溯源，AgentRun = 按 Step 聚合的领域操作记录）。
8. **BYO 兼容**：引擎不跑 LLM；自动步骤是确定性 Action，人工步骤等的是"人"的信号；需 LLM 的步骤仍由用户侧 OpenClacky 完成（经 MCP 工具/信号回引擎）。D1/D3 不受影响。

## 后果（Consequences）

- **正面**：复杂多步编排由引擎承载；人工步骤一等公民（不用把流程拆成多段独立 run）；事件溯源审计天然；多租户隔离由 partition 提供；子 workflow 支持复用与嵌套。
- **代价/风险**：
  - Runic 官方 `~> 0.1.0-alpha`（实验期）→ **v1 锁版本 + 写适配层**（隔离 jido_runic 内部 API），未来可替换自研 DAG 或升级稳定版。
  - 异步 Signal 路径需**幂等键与重试策略**（v1 设计阶段明确），避免重复通知/重复衍生。
  - 人工步骤需定义**超时/取消语义**（如报名截止后取消 run）。
  - 引擎与业务 context 的边界需要纪律：依赖方向恒为 workflow → 业务 Action 接口，业务侧不得反向调引擎。

## 决策依赖

- ADR-0001（BYO/MCP server 架构）
- grill 决策 D1-D14（尤其 D5/D6/D9/D12：通道、审计、workspace_id 作用域）
- workflow-engine-ddd-design.md（Jido 生态调研与设计定稿，见 docs/04-引擎验证/）
