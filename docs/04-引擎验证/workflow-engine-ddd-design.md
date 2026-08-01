# CGC 平台 Workflow 引擎 DDD 设计 — 调研结论与定稿

- 角色：Jido/Workflow架构研究员（worker_4cfa7aa2）
- 日期：2026-08-01
- 状态：已与用户（方伯）逐点讨论并达成共识 ✅

---

## 1. 调研结论（Jido 生态）

### 1.1 Jido 核心五件套
| 构件 | 职责 |
|---|---|
| **Action** | 纯函数步骤，`run/2` 返回状态更新 + directives；可含副作用（API/DB 调用），schema 驱动输入校验 |
| **Signal** | CloudEvents 消息，`type` 字段路由到 action；`source/subject/data` 标准化信封，天然跨模块通信 |
| **Directive** | 副作用指令：`Emit`（发信号）/ `SpawnAgent`（子 agent）/ `Schedule`（调度）等，由运行时执行 |
| **Strategy** | 执行策略，`cmd/3` 处理指令、`signal_routes/1` 路由信号；可自定义（如 step 模式、轮询） |
| **Agent** | 运行时容器（AgentServer GenServer），`call/cast` 收发信号；`use Jido.Agent` 定义 |

### 1.2 jido_runic — DAG workflow 引擎桥接（核心选型）
- **Runic.Workflow** = 数据流 DAG：Step 是 `input → output` 函数，Fact 是数据流单元，**lazy 并发求值**，天然支持分支/并行/扇出。`Workflow.react_until_satisfied/2` 执行。
- **ActionNode**：把任意 Jido Action 包装成 workflow 节点（自动从 schema 推导输入）。
- **SignalMatch**：按 signal type 前缀模式**门控下游执行** → 即"人工步骤/等待事件"的原生机制。
- **JidoRunic.Strategy**：把 DAG 塞进 Jido agent 循环，`execution_mode: :auto|:step`。
- **SignalFact**：Signal ↔ Fact 双向适配，保留溯源链（jidocause → fact ancestry）。
- **Introspection**：`provenance_chain` + `execution_summary` → 支撑审计。
- **Directive.ExecuteRunnable**：调度 Runic runnable 执行。

### 1.3 ash_jido — Ash 桥接
编译期把 Ash Resource 的 action 生成 Jido Action 模块；context 需 domain/actor/tenant。即：**业务实体 ↔ workflow 步骤的桥**。

### 1.4 多租户 / 持久化 / 可观测
- **partition** = 租户/Workspace 隔离（registry identity、persistence、lineage、telemetry 按 partition 隔离）；**Pod** = 持久化 agent 团队（durable topology）；**InstanceManager** = 单个持久 agent（hibernate/thaw）。
- **Storage**：Thread（append-only journal，审计/事件日志）+ Checkpoint（状态快照，断点恢复）。
- **Observability**：telemetry 事件（[:jido, :agent, :cmd, ...] / [:jido, :agent_server, :signal/directive, ...]）、jido_trace_id/jido_span_id、结构化 JSON 日志、redact_sensitive。

### 1.5 选型风险
- Runic 官方 `~> 0.1.0-alpha`（实验期）；jido_runic 版本 0.1.0。
- **用户已决策**：接受作为底层引擎，v1 锁版本 + 写适配层（后续可替换）。

---

## 2. 与用户讨论达成的设计定稿

### 2.1 草案 A：核心模型（已确认 + 细化）
- **WorkflowDefinition（蓝图）** = Runic.Workflow DAG + 元数据（id/name/type/version/输入schema/节点定义）。教研 workflow 定义一次，被 Event/Course 实例化复用；带版本管理（改定义不影响已开始 run）。
- **WorkflowRun（执行实例）** = 一个运行中的 DAG：状态机 `pending → running → waiting(人等信号) → succeeded/failed/cancelled`；持输入快照、产物(facts)、signal 日志；归属 partition。
- **Step（节点）四分类**：
  1. 自动步骤（Jido Action）
  2. 人工步骤（SignalMatch 门控等待外部信号；如报名表单提交、审批）
  3. 门控/分支
  4. 子 workflow（嵌套 DAG）
- **人工步骤模式决策：workflow 内部等待（Human-in-the-loop）为主**，不拆多段。
  - WorkflowRun 是有状态实体：执行到人工节点 → `waiting` 挂起；人操作后发 Signal（如 `enrollment.submitted`）→ `SignalMatch` 放行 → 恢复执行。Y 是 DAG 下游节点，X 完成后 workflow 自动走到 Y，人触发的是"恢复"而非"启动下一段"。
  - 长等待资源占用由 **hibernate/thaw** 解决（waiting 时落 checkpoint 休眠，信号到达 thaw 恢复）。
  - **超时唤醒（F7 方案 A，2026-08-01 用户拍板）**：人工审批等待可配置 `approval_timeout`（默认 7 天，null=无超时）——waiting 时登记 deadline，到点由 hibernate 恢复检查 / Schedule Directive 唤醒 → run 转 `expired`（状态机新增终态）+ 业务实体转 expired（≠ rejected，可重提），deadline 前 48h 提醒审批人；与 F2（报名截止 cancel）同一唤醒机制（§4 遗留风险补充）。
  - 拆多段（独立 run + 人为/订阅触发）仅在未来"段间有明显人为决策间隔且输入差异大"时再考虑；v1 由子 workflow 覆盖"相对独立段"。

### 2.2 草案 B：跨 context 解耦（已确认）
- Workflow 引擎 context **不直接依赖**业务 context。
- workflow 步骤通过 ash_jido 暴露的业务 Action 读/写数据，或发 Signal（CloudEvents）由业务 context 订阅后更新自己的 aggregate（如报名 workflow 产物 → Enrollment）。
- **依赖方向恒为：workflow → 业务 action 接口**；业务 context 反向只发信号、不调引擎。
- **同步 vs 异步决策（8:2）**：
  - **同步直接调 Ash Action（强一致）**：业务核心状态的主写入口，写完立即可读/约束检查。例：报名 workflow 最后一步创建 Enrollment（保证名额/唯一性不变量）。
  - **发 Signal 异步最终一致**：衍生副作用 / 跨 context 通知。例：`enrollment.completed` → 赞助权益更新、通知志愿者、触发学习 workflow。
  - 理由：先把报名/开课主链路做稳；通知与衍生动作走信号，松耦合、可扩展。
- **谁设计 / 谁使用**：
  - 设计者：Admin/Owner 定义平台运维与教研 workflow 模板（WorkflowDefinition，带版本）；Tutor 通过教研 workflow 产出大纲/材料。
  - 使用者：Tutor/Learner/Volunteer/Sponsor 运行 workflow **实例**，不直接改定义。
  - 落地形态：业务 context 定义"我能做什么（Action）/ 我关心什么（Signal）"，workflow 编排"何时做、按什么顺序"。

### 2.3 草案 C：多租户与审计（已确认）
- 每个 **Workspace = 一个 Jido partition**；WorkflowRun 归属 partition（registry identity、persistence、lineage、telemetry 隔离）。
- **审计 context 数据源 = Jido Storage Thread journal**（append-only + Checkpoint + Introspection 溯源链），不另造轮子。

---

## 3. 与业务上下文的对应关系

| 业务决策 | 落地点 |
|---|---|
| workflow-first + WorkflowDefinition/WorkflowRun | 草案 A 核心模型 |
| 教研与学习两个独立 workflow（Tutor 教研 → Event/Course 实例化 → Learner 执行） | WorkflowDefinition 复用 + 实例化；子 workflow 嵌套 |
| Workspace = 组织单元 | partition（草案 C） |
| Enrollment 归活动 context，由报名 workflow 创建 | 跨 context 产物写入：workflow 同步调 create_enrollment Action（草案 B 同步路径） |
| Owner 跨角色 workflow；单步 CRUD 用表单 | workflow 承载多步编排；表单提交 = 人工步骤 Signal 触发 |
| BYO 全链路数字化（Learner 自备 OpenClacky） | 学习执行 workflow 在 Learner 侧运行，通过 Signal 与平台通信 |
| 两级赞助 / Speaker 邀请 / Visitor 报名 | 各自 workflow（赞助 workflow、邀请 workflow、报名 workflow），核心写走 Action、衍生走 Signal |

---

## 4. 遗留风险与后续

- Runic alpha：锁版本（~> 0.1.0）+ 适配层隔离，未来可替换自研 DAG 或升级稳定版。
- 幂等/补偿：异步 Signal 路径需在 v1 设计阶段明确幂等键与重试策略（建议纳入后续任务）。
- 人工步骤超时：waiting 状态需定义超时/取消语义（如报名截止后取消 run）。
- **审批超时（F7 方案 A，2026-08-01 用户拍板）**：`approval_timeout`（默认 7 天，null=无超时）驱动 hibernate deadline + Schedule Directive 唤醒路径——waiting 时登记 deadline（= 进入时间 + approval_timeout），到点由「hibernate 恢复时检查 deadline → Emit cancel」或 Schedule Directive 唤醒 → run 转 `expired`（WorkflowRun 状态机新增终态）+ 业务实体（Enrollment/Sponsorship）转 expired（≠ rejected，可重提），deadline 前 48h 发提醒。**与 F2（报名截止 cancel 唤醒）同一机制**：一次实现 deadline 唤醒路径，F2 报名截止 + F7 审批超时两处受益；v1 集成测试合并验证（见 `docs/03-决策记录/开放问题决策清单.md` F7）。

*（最终架构定稿由 Leader 汇总；本文档为调研与设计要点的原始产出。）*
