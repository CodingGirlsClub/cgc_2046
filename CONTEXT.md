# CGC 平台领域术语表（CONTEXT.md）

> **单一事实源**：本文件是 CGC 平台全部领域术语的权威出处。代码、文档、Issue、测试命名一律使用本表词汇，不引入同义词。
> 日期：2026-08-01 ｜ 维护：领域建模工程师 ｜ 依据：`docs/01-定稿设计/领域模型定稿.md`（2026-07-31）+ `docs/03-决策记录/grill-决策记录-2026-08-01.md`（D1–D14 + D-A1–D-A7）+ `docs/04-引擎验证/workflow-engine-ddd-design.md`
> 状态：**已整合 BYO/MCP 时代术语**（D1–D14 决策全量落盘）+ **workflow 引擎术语**（D-A 系列，依据 Jido 设计稿；领域模型定稿将随后同步）

---

## 0. 架构范式（一句话）

> **网站 = 业务中枢 + MCP server；用户自带 OpenClacky 做 Agent 执行（BYO，自带模型）。**
> 网站不再自行运行 LLM/Agent，只负责业务状态、鉴权、审计；一切 AI 执行发生在用户本地的 OpenClacky，通过 MCP 协议调用网站的领域能力。

---

## 1. 顶层范式概念

### BYO（自带模型，Bring Your Own Model）

- **定义**：用户自带本地 OpenClacky 作为其 Agent 执行环境，平台不承担任何 LLM 推理成本与执行环境；平台只提供领域数据与业务能力。
- **架构位置**：连接范式。决定产品形态——网站 UI 无对话/执行页（D4），聊天发生在用户自己的 OpenClacky；平台零 AI 成本（D3）。

### MCP server（模型上下文协议服务端）

- **定义**：网站暴露的、供用户 OpenClacky 调用的协议端点。技术选型 **anubis_mcp**（Elixir/Phoenix，活跃维护）。全平台**只暴露一个** MCP server（D6）。
- **架构位置**：B 通道主干（见下）。网站能力以"工具"形态暴露给 Agent。

### B 通道（网站 MCP server 通道）—— 主干

- **定义**：用户 OpenClacky → 网站 MCP server 的连接方向，是平台唯一的对外通道。
- **架构位置**：D5。取代原 A 通道，承载一切 Agent 对平台的读写操作。

### A 通道（网站派活通道）—— 已删除

- **定义**：原设计中"网站向用户 OpenClacky 派发任务"的通道。
- **架构位置**：D5 明确废弃。网站不再主动派活；网站通过暴露 MCP server 被用户调用（出站、无隧道）。

### 连接器扩展 cgc-2046（Connector Extension）

- **定义**：用户侧 OpenClacky 的官方扩展，id/名称统一为 `cgc-2046`；安装后提供 CGC 助手、本地 Skill 同步、MCP 连接读取等能力（D14）。**负责自动配置 mcp.json**——安装后自动检查并安装 MCP（网站只生成 token，用户不再手动粘贴配置片段，D-A7）。
- **架构位置**：用户侧入口。`openclacky ext install <zip URL>` 安装（D13 步骤 2 / D-A7）；扩展自动写入 `mcp.json` 的 cgc 条目获取 URL + token，零额外配置。

### CGC 助手（CGC Assistant）

- **定义**：连接器扩展静态内置的**通用** Agent。用户在 OpenClacky 中说"用教研 Agent"时，助手按任务指令模式拉取 Agent 定义并按定义工作（D10）。
- **架构位置**：用户侧执行体，网站侧没有对应资源；它是"公共 Agent 分发"的执行载体。

---

## 2. 身份与多租户

### User（用户，全局资源）

- **定义**：全局账号，一人多 Workspace。可带 `is_platform_admin` 平台管理员标记（可多人）。
- **架构位置**：全局资源（不按租户隔离），认证经 `ash_authentication`（Password 策略 + TokenResource）。

### Identity（认证身份，全局资源）

- **定义**：用户的一种认证方式（provider），与 User 多对一。
- **架构位置**：全局资源，登录态来源。

### Token（登录令牌，全局资源）

- **定义**：网站 UI 登录用的短期 JWT，存 httpOnly cookie；与 MCP **连接 token** 是两种不同的 token（勿混）。
- **架构位置**：全局资源，仅用于网站自身 GraphQL API 的认证。

### Workspace（工作区，全局资源）

- **定义**：**组织单元**（如"北京 CGC 分会"），也是租户单元。UUID 主键 + 全局唯一 slug（展示用），带加入策略 `join_policy`（open | request | invite_only）。由平台管理员创建（申请审批 + 主动创建两级，D-A3）并指定 Owner，普通用户不可自助创建。**一个 Workspace = 一个 Jido partition**（D-A5）。
- **架构位置**：全局资源；所有租户资源以 `workspace_id` 列过滤（Ash attribute 多租户策略）；WorkflowRun 等 workflow 实体归属其 partition。

### join_policy（加入策略）

- **定义**：Workspace 的三种加入方式：`open`（公开可发现、直接加入、无需审批）、`request`（公开可发现、申请后审批）、`invite_only`（私密、仅邀请链接可加入）。
- **架构位置**：Workspace 属性，Owner 可设置；驱动 Invitation / JoinRequest 行为。

### WorkspaceMembership（成员关系，租户资源）

- **定义**：1 条/人/租户的成员记录（user_id + workspace_id + 加入时间 + 邀请人）。
- **架构位置**：成员身份的事实来源；授权链第 2 步"定位身份"读它。

### MembershipRole（成员角色关联，租户资源）

- **定义**：membership ↔ Role 的 N:M 关联表。一人多角色由此表达。
- **架构位置**：权限判定时"所有角色权限取并集"的数据基础。

### 成员资格上下文（MembershipContext）

- **定义**：「actor ↔ 工作台」成员资格读取面的唯一归属：`membership_of/2`、`role_names/2`（角色名多角色并集，Rbac 同名委托）、`memberships_of_actor/1`（跨租户）、`owner_count/1`、`resolve_workspace_id/1`（policy 场景的 filter/changeset 目标工作台解析，含 Ash filter struct 提取钉测）。
- **旁路读取面（BypassReads）**：「唯一允许原始 SQL 的出口」——`member_count/1`（GROUP BY 聚合）与 `shared_workspace_ids/1`（actor 已加入工作台集合）；平铺展示字段（`WorkspaceMembership.user_email`/`user_display_name` LEFT JOIN）同属此契约。安全契约成文：主查询仍受 policy 门控、旁路仅限聚合与平铺展示字段、新读路径先查此处不发明新逃生舱（2026-08-02 ③ 逃生舱收敛）。
- **WorkspaceShell（工作区管理壳）**：前端展示层 seam（2026-08-02 ⑤ 壳收敛；#79 IA）——sidebar/退出登录/未认证壳/共享 Icon 集的唯一实现，interface `slug + children`（`requireWs` 供 profile 家族关闭 ws 解析）；members/permissions/profile/portfolio 四页退化为纯内容，加导航项不再改 4 个页面；导航激活态由 pathname 派生；管理项按 `myAbilities` 过滤（成员与角色=list_members、加入策略=update_join_policy，B-3 审批/邀请占位同组），普通成员仅见 概览/个人资料；profile 家族（`requireWs=false`）ws 不解析 → 能力为空 → 管理项恒隐藏（保守方向，页面级门控不变，后端 policy 权威拦截）。
- **架构位置**：Rbac（判定）与 WorkspaceActorIsOwnerOrAdmin policy / CurrentMembershipInfo 计算字段（读取方）之间的数据 seam（2026-08-02 ② 成员资格读取收敛）：读取形状唯一实现，Ash 升级只炸本模块一处；判定语义仍在 Rbac。

### Role（角色，租户资源）

- **定义**：租户内角色实体，权限挂在角色上。**当前为静态六枚举**（2026-08-02 拍板，见总纲角色扩展注记）：owner / admin / member / tutor / volunteer / learner；member 为默认兜底成员角色，UI 角色分配/展示模板为五角色（不含 member，只作兼容输入）。「自定义角色」为未来能力：触发条件 = 真实工作区角色差异化需求（预计 workflow 定制场景，F 切片之后），届时增量落地 permissionMatrix 租户查询 + Role 能力配置，登记于 GitHub backlog。
- **架构位置**：RBAC 核心；Step/Agent 上存 `role_id` 引用。

### 平台管理员（Platform Admin）

- **定义**：全局标记（`is_platform_admin`，非租户角色），可多人；负责创建 Workspace 并指定 Owner。
- **架构位置**：User 上的布尔标记，跨租户生效。

### 连接 token（MCP 连接令牌 / Connection Token）

- **定义**：每用户一个的 MCP 认证凭证。**绑用户、不绑工作区**；可访问用户加入的多个 Workspace，具体租户由每次调用的目标资源（workspace_id）判定（D6/D13）。在网站"连接设置"页生成。
- **架构位置**：MCP server 的 `Authorization: Bearer <token>` 头；`mcp.json` 是它的单一配置点。**区别于网站登录 Token**：登录 Token 是 httpOnly cookie，只用于网站 UI。
- ⚠️ 注意：本术语**取代**更早调研文档（`docs/02-调研分析/OpenClacky扩展调研与实施计划.md` §3.4）中"token 绑 workspace_id"的旧设计——D13 定稿为绑用户不绑工作区。

### workspace_id 作用域（Workspace Scope）

- **定义**：无状态的租户作用域。**所有 MCP 工具必填 `workspace_id`**，每次调用据此鉴权 + 审计；服务端不存"当前工作区"会话状态（D12）。
- **架构位置**：决定性事实——OpenClacky 的 MCP client 是 server 级全局长连接（`@clients = {name => Client}`，进程级共享），服务端存会话状态会跨会话串。因此 scope 必须无状态、每调用判定。

### 当前工作区（Current Workspace，对话上下文概念）

- **定义**：用户在对话中"正在处理的工作区"，由 CGC 助手维护，而非服务端状态；助手用 `get_workspace_context(workspace_id)` 定向获取上下文（返回角色/可见 Agents/Skills/Steps）。
- **架构位置**：对话侧概念，落在 CGC 助手提示词与工具调用参数里。

---

## 3. 角色、权限与审计

### RBAC（基于角色的访问控制）

- **定义**：平台自研的授权模型：角色（租户内 Role 实体）× 操作 × 资源；多角色取并集，命中任一角色即放行。
- **架构位置**：MCP 调用 = 用户本人身份 + 网站 RBAC 强制（D6）。Agent 权限 = 用户权限，越权被拒。不采用编译期写死的 `ash_rbac`。

### Agent 两层授权（取并集）

- **定义**：① 独立使用：Agent 自身声明"哪些角色可直接用我"（默认创建者角色 + Admin/Owner）；② Workflow 内使用：跟随 Step 的执行角色。两层取并集。
- **架构位置**：`AGENT_ROLE`（独立使用授权）与 `STEP_ROLE`（Step 执行角色）两张显式关联表，均引用 `ROLE.id`。

### 授权最小单元 = Workflow Step

- **定义**：授权不落在 Workflow 整体，而落在每个 Step：每个 Step 声明"哪些角色可执行本步 + 本步用哪个 Agent"。
- **架构位置**：堵死学员误用公共 Agent——学员只能执行自己角色对应的 Step，其他 Step 的 Agent 不可见。

### 工具 = 形状、租户 = 过滤器、每次工具调用 = 审计记录（Tool-Shape Principle）

- **定义**：MCP 工具只定义"能做什么"（形状）；同一个工具对所有人形状相同，能访问哪些数据由租户/角色过滤决定；每一次工具调用都必须落审计。
- **架构位置**：D6 总原则，贯穿 MCP 工具集、workspace_id 作用域与 AgentRun 审计。

### 能力接口（Capability Interface）

- **定义**：平台向消费端（Web UI 与未来 MCP 工具）暴露的权限判定契约：`permissionMatrix`（角色→能力矩阵，abilities 为通用 `[{name, allowed}]` 列表）、`myAbilities`（当前用户在目标工作台的能力并集，随 `meWorkspaces` 下发）、角色名仅作展示词汇（徽章/筛选/标签）。消费端**不复写权限语义**：不做角色名→能力推断、不维护本地矩阵副本；能力/角色词汇唯一真源在后端 `Role`/`Rbac` 单源，经 `backend/priv/rbac_contract.json` 契约工件做跨语言 golden-file 守卫（`mix cgc2046.gen_rbac_contract` 再生成）。
- **架构位置**：2026-08-02 契约收敛决策（原 #67 权限矩阵的跨语言 seam 深化）：Web UI 判定全部消费后端下发能力数据；新增角色/能力只改后端单源与前端展示标签（`ROLE_NAMES`/`PERMISSION_ABILITIES`），任何一边漏同步 = CI 红灯；与 ADR-0001「UI 与 MCP 走同一套授权链」一致，为 MCP 工具接入预留同一判定入口。

### 审计记录（Audit Record）

- **定义**：每次 MCP 工具调用（谁/工具/参数/结果/确认/时间）的结构化记录；"无确认不落库"的写操作在确认后落库并审计。
- **架构位置**：AgentRun 的数据基础（见 §5）；二期可接 `ash_paper_trail` 增强。

### partition（租户分区）

- **定义**：Jido 的多租户隔离单元。**一个 Workspace = 一个 partition**（D-A5）：registry identity / persistence / lineage / telemetry 全部按 partition 隔离；WorkflowRun 归属其 partition。
- **架构位置**：workflow 引擎侧的租户边界，与 `workspace_id`（Ash attribute 多租户）对应。

### Thread journal（线程日志审计）

- **定义**：Jido Storage 的 append-only 日志（审计/事件日志）+ Checkpoint（状态快照，断点恢复）+ Introspection（`provenance_chain` 溯源链 / `execution_summary`）。**审计 context 的数据源**（D-A5），不另造轮子。
- **架构位置**：workflow 引擎的持久化与审计底座；与网站侧 ToolCallLog/AgentRun 审计互补。

---

## 4. Workflow 执行模型

> workflow-first（D-A1）：**WorkflowDefinition（蓝图）+ WorkflowRun（执行实例）为核心模型**，引擎选型 Jido（Elixir）生态；构建不做可视化 UI，经 OpenClacky 的构建器 Agent/Skill 产出 DSL 后部署。

### WorkflowDefinition（工作流蓝图）

- **定义**：Runic.Workflow DAG + 元数据（id/name/type/version/输入 schema/节点定义）。教研 workflow 定义一次，被 Event/Course **实例化复用**；带版本管理，改定义不影响已开始 run（D-A1/D-A2）。
- **架构位置**：租户资源；设计者 = Admin/Owner（平台运维与教研模板），使用者运行实例不改定义；部署权限 Owner/Admin/Tutor。

### WorkflowRun（工作流执行实例）

- **定义**：一个运行中的 DAG 实例。状态机 `pending → running → waiting(人等信号) → succeeded/failed/cancelled`；持输入快照、产物（facts）、signal 日志；**归属 partition**（D-A1/D-A5）。
- **架构位置**：执行实例；人工步骤到达时 `waiting` 挂起（hibernate 落 checkpoint，信号到达 thaw 恢复），不拆多段（human-in-the-loop 为主）。

### Step（步骤，四分类）

- **定义**：Workflow 的最小授权单元，声明执行角色集合 + 使用的 Agent（`STEP_ROLE` 关联表授权）；按节点类型分四类：
  1. **自动步骤**（Jido Action，纯函数 + 副作用）
  2. **人工步骤**（SignalMatch 门控等待外部信号，如报名表单提交、审批）
  3. **门控/分支**
  4. **子 workflow**（嵌套 DAG）
- **架构位置**：租户资源；顺序解锁（Step 1 完成才能执行 Step 2）；AgentRun 按 Step 聚合；授权语义与旧 Workflow/Step 模型一致。

### Jido 生态（Jido Ecosystem）

- **定义**：workflow 引擎底层选型（Elixir，D-A1）。核心五件套：**Action**（纯函数步骤）/ **Signal**（CloudEvents 消息）/ **Directive**（副作用指令 Emit/SpawnAgent/Schedule）/ **Strategy**（执行策略）/ **Agent**（运行时容器 AgentServer）。
- **架构位置**：引擎层；加 **jido_runic**（DAG 桥）与 **ash_jido**（业务 Action 桥）组成平台 workflow 底座。

### Signal / CloudEvents（信号）

- **定义**：跨 context 通信的消息信封，`type` 字段路由到 action，`source/subject/data` 标准化。**workflow 与业务 context 解耦的纽带**：workflow 发 Signal → 业务 context 订阅后更新自己的 aggregate；业务反向只发信号、不调引擎。
- **架构位置**：D-A1/D-A6。**同步写走 Action（强一致，8）**，**衍生副作用走 Signal 异步最终一致（2）**——如 `enrollment.completed` → 赞助权益更新、通知志愿者、触发学习 workflow。

### ash_jido（Ash 桥）

- **定义**：编译期把 Ash Resource 的 action 生成 Jido Action 模块（context 需 domain/actor/tenant）；**业务实体 ↔ workflow 步骤的桥**（D-A1）。
- **架构位置**：依赖方向恒为 workflow → 业务 action 接口；workflow 步骤经它同步读/写业务数据（如 `create_enrollment`）。

### Runic DAG（jido_runic）

- **定义**：数据流 DAG 引擎——Step 是 `input → output` 函数，Fact 是数据流单元，lazy 并发求值（分支/并行/扇出）；`react_until_satisfied/2` 执行；**SignalMatch** 按 signal type 前缀门控下游（人工步骤/等待事件原生机制）；**SignalFact** 保留溯源链。官方 `~> 0.1.0-alpha`，v1 锁版本 + 适配层隔离（D-A1）。
- **架构位置**：WorkflowDefinition 的底层执行载体。

### 任务指令模式（Task-Instruction Pattern）

- **定义**：公共 Agent 分发方式——Agent 定义（prompt/skills/授权）**存网站**，MCP 提供 `get_agent_instruction(workspace_id, agent_id)`；用户说"用教研 Agent"→ CGC 助手拉取定义 → 按定义工作。公共 Agent 动态创建天然支持（D10）。
- **架构位置**：替代"运行时下发文件"（热加载未验证、工程风险高）与"纯静态打包"（不支持动态公共 Agent）两条路。

### AgentRun（领域操作聚合记录，租户资源）

- **定义**：按 Step 聚合的"一次干活"记录——操作序列摘要、关联 Step、操作者。网站根据每次 MCP 工具调用**自动生成**，不做用户侧上报（上报不可靠/可篡改、连接器扩展工作量大）（D9）。
- **架构位置**：审计流产出物；用户侧 OpenClacky 对话/token 等执行详情**不进** AgentRun。v1 就做。

---

## 5. Agent 与 MCP 工具集

### Agent（授权/配置登记，租户资源）

- **定义**：两种形态——**个人 Agent**（角色分身，仅本人可见可用）与**公共 Agent**（Workspace 级，按 Workflow 协作）。在 BYO 架构下，Agent 只是授权与配置登记：`type / allowed_roles / owner` + OpenClacky 配置引用（`openclacky_profile / model / system_prompt / skills`）（D2）。**不包含执行逻辑**——执行发生在用户本地 OpenClacky。
- **架构位置**：资源实体 + 网站侧定义存储；经 `get_agent_instruction` 供 CGC 助手消费。

### AgentRun 资源（见 §4）

### MCP 工具集（MCP Tool Set）

- **定义**：网站经 MCP server 暴露的全部工具，分三类（D7）：
  - **读**：`get_workspace_context` / `get_workflow` / `get_step_output` / `list_members` / `get_learner_history` / `get_agent_instruction`（拉取 Agent 定义，D10）
  - **写**：`save_step_output` / `reply_learner_question`
  - **管理类**（进 MCP，RBAC 兜底）：低风险直做 `create_agent` / `create_workflow` 等；高风险走确认流 `approve_join_request` / `assign_role` / `create_invitation` / `update_join_policy` / 删除类
- **架构位置**：B 通道能力面；所有工具必填 `workspace_id`，每次调用鉴权 + 审计。

### 确认流（Confirmation Flow）

- **定义**：高风险 MCP 工具的两阶段提交（D8，方案二原生 request_user_feedback）：
  1. Agent 调高风险工具 → 网站**不落库**，建 pending 记录 → 返回 `needs_confirmation: {id, 摘要}`
  2. Agent 调内置 `request_user_feedback(question, options: ["确认写入", "继续讨论"])` → WebUI 弹可点击卡片，Agent 停下
  3. 用户点选 → 文本回传 Agent → Agent 调 `confirm(id)` → 网站落库 + 审计
  4. **网站永远不偷偷执行：无 confirm 不落库**
- **架构位置**：管理类写操作的安全闸门；已知风险：auto_approve 模式 10s 倒计时自动决策（二期可加冷却期）。

### pending 记录（Pending Record）

- **定义**：确认流中"待确认"的高风险操作暂存，**不落业务库**（业务数据未写入），仅存确认所需信息。
- **架构位置**：确认流的中间态；`confirm(id)` 前业务状态不变。

### needs_confirmation（需确认响应）

- **定义**：网站对高风险工具调用的响应结构：`{id, 摘要}`，指示 Agent 进入确认流。
- **架构位置**：MCP 协议层响应类型。

### request_user_feedback（用户反馈原语）

- **定义**：OpenClacky 内置的提问原语（D8 方案二）；确认流用它把可点击卡片弹到 WebUI。
- **架构位置**：OpenClacky 侧能力，非网站实现。

### confirm（确认动作）

- **定义**：确认流第 4 步——Agent 携带确认 id 调用 `confirm(id)`，网站才落库并审计。
- **架构位置**：MCP 管理类工具族的配套动作；"无 confirm 不落库"的落点。

---

## 6. Skill 与本地同步

### Skill（技能）

- **定义**：OpenClacky 的预设工作流（SKILL.md + scripts/references），带触发描述、工具约束、隔离等 frontmatter。分三级来源：项目级 `.clacky/skills/` → 用户级 `~/.clacky/skills/` → 内置。
- **架构位置**：用户侧能力单元；工作区 Skill 定义**存网站**，经连接器同步到本地（D11）。

### Skill 本地同步（Skill Local Sync）

- **定义**：把工作区 Skill 定义从网站同步到用户本地 `~/.clacky/skills/` 的机制（D11）：扩展 API handler 经 `@http_server` 访问 `@skill_loader`（与 session_manager 同模式），调 `SkillLoader#create_skill / delete_skill` 运行时写文件 + 立即注册（源码验证可行）。
- **架构位置**：连接器扩展 cgc-2046 的能力；触发方式：扩展静态打包 `cgc-sync` skill / 网站 aside 面板按钮。

### 技能前缀 cgc2046-<ws>-<skill>（Skill Prefix）

- **定义**：本地同步技能的命名前缀，含工作区 slug 与技能名，防多工作区撞名（D12/D14）。
- **架构位置**：本地技能命名空间；网站生成 Agent 指令时引用带前缀的本地技能名；MCP server 条目名与扩展 id 统一为 `cgc-2046`。

### 角色过滤（Role Filtering，网站侧）

- **定义**：工作区 Skill 同步时，**网站侧**先按该用户角色过滤可见技能——扩展只拉到该用户角色可见的技能（D11）。
- **架构位置**：同步链路的第一道闸门，安全边界在网站侧。

---

## 7. Onboarding 与连接配置

### Onboarding（一次性三步引导）

- **定义**：用户接入平台的引导流程（D13 简化，D-A7）：
  1. **装 OpenClacky**（网站给安装命令）
  2. **安装连接器扩展**：`openclacky ext install <zip URL>`
  3. **扩展自动检查并安装 MCP**——扩展自动配置 `mcp.json`，网站只生成 token（绑用户不绑工作区）
- **架构位置**：新用户接入路径；加入新工作区无需重新配置（token 通用，scope 靠 workspace_id）。

### mcp.json（单一配置点）

- **定义**：OpenClacky 的 MCP 配置文件；**由连接器扩展自动写入** cgc-2046 条目（URL + token），用户不再手动粘贴配置片段（D-A7，取代 D13 步骤 2 的手动粘贴）。
- **架构位置**：用户侧连接配置唯一事实源。扩展自动检查并安装 MCP，网站只负责生成 token。

### 用户离线（User Offline）

- **定义**：BYO 架构下的已知限制：用户本地 OpenClacky 离线时，该用户的 Agent 任务不可用（D3，接受）。
- **架构位置**：产品约束而非缺陷；平台不持有执行能力。

---

## 8. 其余资源与概念

### Invitation（邀请链接，租户资源）

- **定义**：加入 Workspace 的链接：token（存 hash）、expires_at、邀请人、预授权角色、目标邮箱（空 = 公开链接）、状态（active/used/revoked）。Volunteer 可生成链接但不得赋予 Admin 级角色。
- **架构位置**：租户资源；invite_only 空间唯一入口；撤销流程与到期清理留编码阶段细化。

### JoinRequest（加入申请，租户资源）

- **定义**：request 空间下的加入申请：申请人、Workspace、状态（pending/approved/rejected）；审批通过时分配角色。
- **架构位置**：租户资源；审批动作属于高风险管理工具，走确认流。

### Profile（成员公开资料，租户资源）

- **定义**：头像、简介、标签（含 Portfolio 作品展示）。
- **架构位置**：租户资源；二期需要聚合展示时再拆。

### Event / Course（活动 / 线上课程）

- **定义**：**挂在 Workspace 下**的活动与课程（结构决策，D-A3）：Event 为场地形态（**校园 / 咖啡厅 / 书店 / 联合办公空间**），Course 为线上课程。事件级参与经 **Enrollment**（见下），**不自动成为 Workspace 成员**。
- **架构位置**：租户资源（挂 Workspace）；由 Owner 创建/编辑（单步 CRUD 用表单）；筹备活动/开课程 = 跨角色 workflow。

### Enrollment（报名 / 事件级参与者）

- **定义**：Event/Course 的**事件级参与者记录**，归**活动 context**（D-A4）：由报名 workflow **同步调 `create_enrollment` Action** 创建（强一致：名额/唯一性）；**不自动成为 Workspace 成员**。报名轻量表单 + 全免费（Learner Q3）。
- **架构位置**：活动 context 资源；与 WorkspaceMembership（长期成员）两类关系并存。

### Sponsorship（赞助，两级）

- **定义**：**两级赞助** = Event 级（单场活动）+ Workspace 级（长期）（D-A3）。赞助方以账号身份参与赞助 workflow（意向 → Owner/Admin 审批 → 权益生效），**不必成为成员**。
- **架构位置**：活动/Workspace 资源；权益生效经异步 Signal。

### SpeakerInvitation（分享嘉宾邀请）

- **定义**：**Event 级邀请**（D-A3）：Owner 创建 → 邀请 workflow（接受/拒绝 → 分享材料产出 → 结束）；分享完**关系结束**，不成为成员。
- **架构位置**：活动 context 资源；邀请/接受状态由 Signal 驱动。

### AuditLog（审计日志，二期）

- **定义**：敏感操作留痕的全局日志（二期接 `ash_paper_trail`）；一期以 AgentRun + 每次工具调用审计记录覆盖。
- **架构位置**：二期基础设施。

### 工具 = 形状 原则（见 §3）

---

## 9. 术语使用约定与易混清单

| 易混对 | 区别 |
| --- | --- |
| 登录 Token vs 连接 token | 登录 Token：网站 UI 的 httpOnly cookie（JWT）；连接 token：MCP `Authorization: Bearer` 头，绑用户不绑工作区 |
| A 通道 vs B 通道 | A 通道（网站派活）已删除；B 通道（网站 MCP server）是唯一主干 |
| Agent vs AgentRun | Agent 是授权/配置登记（不含执行）；AgentRun 是网站按 MCP 工具调用自动聚合的领域操作记录 |
| 个人 Agent vs 公共 Agent | 个人 = 角色分身仅本人可见；公共 = Workspace 级按 Workflow 协作 |
| Skill vs Agent | Skill 是预设工作流（SKILL.md）；Agent 是带人格/面板/技能绑定的助手；工作区 Skill 经本地同步进 `~/.clacky/skills/` |
| `cgc-2046` vs `cgc2046-<ws>-<skill>` | `cgc-2046` 是扩展 id / MCP 条目名；`cgc2046-<ws>-<skill>` 是本地同步技能的命名前缀 |
| 确认流 vs 直接执行 | 高风险管理工具必须 pending → request_user_feedback → confirm 才落库；低风险工具（create_agent/create_workflow）直接执行 |
| Workspace 成员 vs Event 参与者 | 成员 = WorkspaceMembership（长期，带角色，可进工作台）；参与者 = Enrollment（事件级，报名产生，不自动成为成员） |
| WorkflowDefinition vs WorkflowRun | 蓝图（Runic.Workflow DAG + 版本）vs 执行实例（pending→running→waiting→succeeded/failed/cancelled，归属 partition） |
| 同步写 vs 异步 Signal | 业务核心状态主写入口走同步 Ash Action（强一致，8）；衍生副作用/通知走 Signal 异步最终一致（2） |

## 10. 待细化/待办（编码阶段）

- Invitation 撤销流程（revoked 状态 + 到期清理）
- JoinRequest 审批的角色分配方式（申请人请求 vs 审批方指定）
- AgentRun 的 token 用量字段（tokens_in/tokens_out）为计费留底
- 确认流 auto_approve 模式的冷却期（二期）
- 平台管理员建 Workspace 的审计留痕
- 人工步骤超时/取消语义（workflow `waiting` 状态：如报名截止后取消 run）
- 异步 Signal 路径的幂等键与重试策略（v1 设计阶段）
- `docs/01-定稿设计/领域模型定稿.md` 同步 workflow 引擎概念（WorkflowDefinition/WorkflowRun/Step 四分类/partition/Thread journal/Enrollment/Sponsorship/SpeakerInvitation）
