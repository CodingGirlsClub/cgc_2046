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
- **工具鉴权立场**（架构深化 C）：豁免声明 = 工具模块自身 `use Anubis.Server.Component` 的 `meta:` opt（`workspace_id: :optional` 免 workspace_id 必填｜`membership: :deferred` 成员门槛下沉工具层授权｜`membership: :public` 公开浏览族——任何持连接 token 的登录用户可用，匿名姿态读在工具层，KTD2/KTD3）；Wrapper 经组件注册派生 name→meta 门控（`:persistent_term` 缓存 + Server 模块 md5 指纹防陈旧）。**未声明 meta 的工具 = member-only + workspace_id 必填（fail-closed 默认）**——例外不再维护于 Wrapper 静态清单。
- **架构位置**：B 通道主干（见下）。网站能力以"工具"形态暴露给 Agent。

### B 通道（网站 MCP server 通道）—— 主干

- **定义**：用户 OpenClacky → 网站 MCP server 的连接方向，是平台唯一的对外通道。
- **架构位置**：D5。取代原 A 通道，承载一切 Agent 对平台的读写操作。

### A 通道（网站派活通道）—— 已删除

- **定义**：原设计中"网站向用户 OpenClacky 派发任务"的通道。
- **架构位置**：D5 明确废弃。网站不再主动派活；网站通过暴露 MCP server 被用户调用（出站、无隧道）。

### 连接器扩展 cgc-2046（Connector Extension）

- **定义**：用户侧 OpenClacky 的官方扩展，id/名称统一为 `cgc-2046`；安装后提供 CGC 助手、本地 Skill 同步、MCP 连接读取等能力（D14）。**负责自动配置 mcp.json**——安装后自动检查并安装 MCP（网站只生成 token，用户不再手动粘贴配置片段，D-A7）。
- **架构位置**：用户侧入口。`openclacky ext install <zip URL>` 安装（D13 步骤 2 / D-A7）；扩展自动写入 `mcp.json` 的 `cgc-2046` 条目获取 URL + token，零额外配置。

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

- **定义**：1 条/人/租户的成员记录（user_id + workspace_id + 加入时间 + 邀请人）。**成员资格本身即成员身份**；无差异标签的普通成员只有 membership、无 MembershipRole。
- **架构位置**：成员身份的事实来源；授权链第 2 步"定位身份"读它。成员基准能力（`view_workspace` / `access_invite_only`）由任意 membership 授予，不再经 `member` 角色判定。

### MembershipRole（成员角色关联，租户资源）

- **定义**：membership ↔ Role 的 N:M 关联表。一人多角色由此表达。
- **架构位置**：权限判定时"所有角色权限取并集"的数据基础。

### 成员资格上下文（MembershipContext）

- **定义**：「actor ↔ 工作台」成员资格**读取与入座（写入）**面的唯一归属：
  - **读取面**：`membership_of/2`、`role_names/2`（角色名多角色并集，Rbac 同名委托）、`memberships_of_actor/1`（跨租户）、`owner_count/1`、`resolve_workspace_id/1`（policy 场景的 filter/changeset 目标工作台解析，含 Ash filter struct 提取钉测）。
  - **入座写入面**：`admit_member/3`（加入工作台不变量的唯一实现）——承担「existing 守卫 → 建 Membership → 按角色名入座 MembershipRole → 并发 unique 处理 → 真 DB 故障上抛」全流程；Invitation.accept / JoinRequest.approve / Workspace.join 三处 after_action 的入座段委托此处（2026-08-05 入座收敛，消除三处同构拷贝）。opts：`:on_conflict`（`:business_error` Invitation/JoinRequest 转「已是成员」业务错误｜`:idempotent` Workspace.join 幂等成功）、`:error_message`（文案随调用方视角：Invitation 对受邀人「你」、JoinRequest 对审批方「该用户」）。事务无关纯函数——事务边界由调用方 action 控制（`:join` 的 `transaction?: false` 孤儿 membership 风险已知，升级路径单独决策）。
- **旁路读取面（BypassReads）**：**聚合读逃生舱**——`member_count/1` / `owner_count/1`（GROUP BY 聚合直读）+ 平铺展示字段（`WorkspaceMembership.user_email`/`user_display_name` LEFT JOIN）契约归类；非全库唯一原始 SQL 出口（#217 契约改写，2026-08-20）：resolver 旁路读取 14 处与原始 SQL 六类分布的中央契约见该模块 moduledoc。安全契约成文：主查询仍受 policy 门控、旁路仅限聚合与平铺展示字段、新读路径先查此处不发明新逃生舱（2026-08-02 ③ 逃生舱收敛）。
- **WorkspaceShell（工作区管理壳）**：前端展示层 seam（2026-08-02 ⑤ 壳收敛；#79 IA）——sidebar/退出登录/未认证壳/共享 Icon 集的唯一实现，interface `slug + children`（`requireWs` 供 profile 家族关闭 ws 解析）；members/permissions/profile/portfolio 四页退化为纯内容，加导航项不再改 4 个页面；导航激活态由 pathname 派生；管理项按 `myAbilities` 过滤（成员与角色=list_members、加入策略=update_join_policy，B-3 审批/邀请占位同组），普通成员仅见 概览/个人资料；profile 家族（`requireWs=false`）ws 不解析 → 能力为空 → 管理项恒隐藏（保守方向，页面级门控不变，后端 policy 权威拦截）。
- **架构位置**：Rbac（判定）与 WorkspaceActorIsOwnerOrAdmin policy / CurrentMembershipInfo 计算字段（读取方）之间的数据 seam（2026-08-02 ② 成员资格读取收敛）：读取形状唯一实现，Ash 升级只炸本模块一处；判定语义仍在 Rbac。入座写入面（`admit_member/3`）收敛三处加入流程的建 Membership + 角色入座 + unique 处理同构拷贝（2026-08-05 入座收敛，近 10 次提交反复修同类 bug 的 locality 缺失被根除）。

### Role（角色，租户资源）

- **定义**：租户内**差异标签**实体，权限挂在角色上。**当前为静态五枚举**（plan 017 / ADR-0006，退役 `member`）：owner / admin / tutor / volunteer / learner。成员资格 = 存在 `WorkspaceMembership`；Role 只表达差异（管理、教学、志愿、学员）。`learner` 仍有真实语义（学习 run 的 StepRole / enrolled_learner）。「自定义角色」为未来能力（#71）：触发条件 = 真实工作区角色差异化需求，届时增量落地 permissionMatrix 租户查询 + Role 能力配置。
- **架构位置**：RBAC 核心；Step/Agent 上存 `role_id` 引用。

### 平台管理员（Platform Admin）

- **定义**：全局标记（`is_platform_admin`，非租户角色），可多人；负责创建 Workspace 并指定 Owner。
- **不变量**：系统必须维持 ≥1 名平台管理员；降级最后一名管理员被拒绝（不变量由 `User :demote_platform_admin` action 守卫）。
- **架构位置**：User 上的布尔标记，跨租户生效。**判定唯一真源 = `Cgc2046.Policies.PlatformAdmin`**（2026-08-12 named-check 收敛）：Ash check（`match?/3`）+ 纯谓词 `platform_admin?/1` 两个 surface，policy 字面量与 plug/live/graphql ad-hoc 判定全部收口。**双面契约**：policy 面放行跨租户治理读（含成员列表，load-bearing，实 bug `7f925b7`）；能力面（Rbac abilities / myAbilities）不给非成员管理员管理类 ability（#66 P2）——两面刻意不同答，契约成文于该 module moduledoc。

### 连接 token（MCP 连接令牌 / Connection Token）

- **定义**：每用户一个的 MCP 认证凭证。**绑用户、不绑工作区**；可访问用户加入的多个 Workspace，具体租户由每次调用的目标资源（workspace_id）判定（D6/D13）。在网站「MCP」页生成。
- **架构位置**：MCP server 的 `Authorization: Bearer <token>` 头；`mcp.json` 是它的单一配置点。**区别于网站登录 Token**：登录 Token 是 httpOnly cookie，只用于网站 UI。
- **生命周期**：**滚动过期（#211 裁决，2026-08-18）**——连续 **90 天未使用即失效**（`last_used_at`/`inserted_at` 距今 ≥ 90d 时 `validate_token` 拒绝）；正常使用不断、无需重签。仅手动撤销 + 每用户 active 上限 10 枚；**无固定 TTL**（与 D-A7 零配置接入冲突：静默到期会让 agent 断连且引导链路长，泄漏窗口收敛与滚动过期相当）。参考实现 `Cgc2046.Mcp.Token`。
- ⚠️ 注意：本术语**取代**更早调研文档（`docs/02-调研分析/OpenClacky扩展调研与实施计划.md` §3.4）中"token 绑 workspace_id"的旧设计——D13 定稿为绑用户不绑工作区。

### workspace_id 作用域（Workspace Scope）

- **定义**：无状态的租户作用域。**除两类豁免外，所有 MCP 工具必填 `workspace_id`**：`meta: %{workspace_id: :optional}` 声明的工具（confirm_operation / cancel_operation），以及 `meta: %{membership: :public}` 的公开浏览工具（list_public_offerings / get_public_offering——跨工作区公开白名单口径，workspace_id 传入也不收窄，KTD3）。其余工具每次调用据此鉴权 + 审计；服务端不存"当前工作区"会话状态（D12）。
- **meta 载体纪律**：`meta:` 仅存门控事实（workspace_id 必填性 / membership 豁免）——Anubis 会把非 nil meta 序列化进 tools/list 的 `_meta` 对 MCP 客户端可见，塞其他用途的键等于向客户端泄漏非门控信息（架构深化 C 遗留约定）。
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
- **架构位置**：D6 总原则，贯穿 MCP 工具集、workspace_id 作用域与 ToolCallLog 审计。

### 能力接口（Capability Interface）

- **定义**：平台向消费端（Web UI 与未来 MCP 工具）暴露的权限判定契约：`permissionMatrix`（差异标签→能力矩阵，abilities 为通用 `[{name, allowed}]` 列表）、`myAbilities`（当前用户在目标工作台的能力并集，随 `meWorkspaces` 下发；任意 membership 即有成员基准 `view_workspace`/`access_invite_only`）、角色名仅作差异标签展示词汇（徽章/筛选）。消费端**不复写权限语义**：不做角色名→能力推断、不维护本地矩阵副本；能力/角色词汇唯一真源在后端 `Role`/`Rbac` 单源，经 `backend/priv/rbac_contract.json` 契约工件做跨语言 golden-file 守卫（`mix cgc2046.gen_rbac_contract` 再生成）。
- **架构位置**：2026-08-02 契约收敛 + 2026-08-15 plan 017 / ADR-0006（member 退役）：Web UI 判定全部消费后端下发能力数据；新增角色/能力只改后端单源与前端展示标签（`ROLE_NAMES`/`PERMISSION_ABILITIES`），任何一边漏同步 = CI 红灯；权限映射页按「成员基准 + 差异标签」展示，无 member 独立行。

### 审计记录（Audit Record）

- **定义**：每次 MCP 工具调用（谁/工具/参数/结果/确认/时间）的结构化记录；"无确认不落库"的写操作在确认后落库并审计。
- **架构位置**：MCP 审计的**事件账本与唯一原始记录**——AgentRun 家族的一切聚合视图都是它的投影（见 §4 AgentRun 词条）。二期可接 `ash_paper_trail` 增强。

### partition（租户分区）

- **定义**：Jido 的多租户隔离单元。**一个 Workspace = 一个 partition**（D-A5）：registry identity / persistence / lineage / telemetry 全部按 partition 隔离；WorkflowRun 归属其 partition。
- **架构位置**：workflow 引擎侧的租户边界，与 `workspace_id`（Ash attribute 多租户）对应。

### Thread journal（线程日志审计）

- **定义**：Jido Storage 的 append-only 日志（审计/事件日志）+ Checkpoint（状态快照，断点恢复）+ Introspection（`provenance_chain` 溯源链 / `execution_summary`）。**审计 context 的数据源**（D-A5），不另造轮子。
- **架构位置**：workflow 引擎的持久化与审计底座；与网站侧 ToolCallLog 审计互补。

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
- **架构位置**：租户资源；顺序解锁（Step 1 完成才能执行 Step 2）；授权语义与旧 Workflow/Step 模型一致。

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

- **定义**：公共 Agent 分发方式——Agent 定义（prompt/skills/授权）**存网站**，MCP 提供 `get_agent_instruction(workspace_id, agent_id)`（**roadmap**：随 Agent 资源落地实现，#211 裁决 1/3；v1 载体 = `AgentInstructions` 模块常量）；用户说"用教研 Agent"→ CGC 助手拉取定义 → 按定义工作。公共 Agent 动态创建天然支持（D10）。
- **架构位置**：替代"运行时下发文件"（热加载未验证、工程风险高）与"纯静态打包"（不支持动态公共 Agent）两条路。

### AgentRun（领域操作聚合记录，实体不建）

- **定义**：按"一次干活"聚合操作序列的概念（D9：操作摘要、关联对象、操作者，网站自动生成、不做用户侧上报）。**实体不落地（#211 裁决 2/3，2026-08-18）**：原设计的聚合锚先后被架构演进移除——Agent 实体不建模（形态 X / BYO，R2 已删 `Step.agent_id`）、主链路不再经过 Step（学习/教研锚 user × course，切片 H），"按 Step 聚合"的实体形态已失效。
- **架构位置**：审计义务由 **ToolCallLog 事件账本**承担（D9 的自动记录/防抵赖已兑现）；AgentRun 语义 = ToolCallLog 之上的**投影**，可从流水回填重建，不建写模型。结果账本按 context 就位：LearningRecord（学习）/ ResearchOutput（教研）/ WorkflowRun.facts（Step 链路产物）。
- **重启条件**：Agent 资源落地（roadmap：plan 020，`get_agent_instruction` 切库）或多宿主（OpenClacky / OMP / OpenCode / DSH）会话归因需求成真 → 从 ToolCallLog 投影重建；**前置 = 流水补 `client_name` / `session_id` 归因维度**（模型可重算、流水维度不记则历史不可回填，#228）。

---

## 5. Agent 与 MCP 工具集

### Agent（授权/配置登记，租户资源）

- **定义**：两种形态——**个人 Agent**（角色分身，仅本人可见可用）与**公共 Agent**（Workspace 级，按 Workflow 协作）。在 BYO 架构下，Agent 只是授权与配置登记：`type / allowed_roles / owner` + OpenClacky 配置引用（`openclacky_profile / model / system_prompt / skills`）（D2）。**不包含执行逻辑**——执行发生在用户本地 OpenClacky。
- **架构位置**：授权/配置登记概念，**实体未落地**（roadmap：plan 020，与 AgentRun 重启条件同钩子，#211 裁决 2/3）；v1 载体 = `Cgc2046.Workflows.AgentInstructions` 模块常量，`get_agent_instruction` 工具随实体落地（#211 裁决 1/3）。

### MCP 工具集（MCP Tool Set）

- **定义**：网站经 MCP server 暴露的工具面（**D7 收窄 + 分层，#211 裁决 1/3，2026-08-18**），当前 **17 个**（名单由 `wrapper_gate_test` 钉死）：
  - **读 9**：`get_workspace_context` / `get_workflow` / `get_step_output` / `list_members` / `list_join_requests`（成员管理 #240）/ `get_course_content` / `get_learning_records`（后两个为切片 H #180 课程学习闭环，已实现）/ `list_public_offerings` / `get_public_offering`（公开浏览 #293，`membership: :public` 豁免家族：任何持连接 token 的登录用户，跨工作区匿名白名单口径，KTD2/KTD3）
  - **写 3**：`save_step_output` / `save_learning_records` / `save_course_content`
  - **确认流 5**：`create_invitation` + `approve_join_request` / `assign_roles`（成员管理主循环——Owner/Admin「批加入 + 给角色」，#211 裁决 1/3 拍板、#240 实现为确认流 two-tool 写）+ 内置 `confirm_operation` / `cancel_operation`
  - **挂 Agent 资源 roadmap**（与 §4 AgentRun 重启条件同钩子）：`create_agent` / `create_workflow` / `get_agent_instruction`——上游实体/输入形状不存在，落地时机随 Agent 资源
  - **已死亡（标注取代后除名）**：`reply_learner_question`（被 issue 卡 checklist 复盘 + `save_learning_records` 取代，切片 H）；`get_learner_history`（被 `get_learning_records` 取代）
- **架构位置**：B 通道能力面；鉴权立场随工具走（工具自身 meta 声明 + Wrapper 派生门控，fail-closed 默认：未声明 = member-only + workspace_id 必填），每次调用鉴权 + 审计。`update_join_policy` / 删除类等低频管理操作维持 web 面（GraphQL + 设置页），真实 agent-first 需求出现时按「确认流 + RBAC 兜底」范式增量重开。

### 确认流（Confirmation Flow）

- **定义**：高风险 MCP 工具的两阶段提交（D8；实现为 **two-tool 模式**，D-D3——目标客户端均不支持 elicitation）：
  1. Agent 调高风险工具 → 网站**不落库**，建 pending 记录 → 返回 `needs_confirmation: {id, 摘要}`
  2. Agent 向用户展示摘要并征得同意（OpenClacky 语境经 `request_user_feedback` 原语弹卡片）
  3. 用户同意 → Agent 调 `confirm_operation(id)` → 网站落库 + 审计；拒绝 → `cancel_operation(id)`（pending TTL 10 分钟）
  4. **网站永远不偷偷执行：无 confirm 不落库**
- **架构位置**：管理类写操作的安全闸门；已知风险：auto_approve 10s 倒计时自动决策（二期可加冷却期）。

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

- **定义**：确认流第 3 步——Agent 携带 pending id 调用内置工具 `confirm_operation(id)`，网站才落库并审计；拒绝则 `cancel_operation(id)`。
- **架构位置**：确认流高风险工具族的配套动作；"无 confirm 不落库"的落点。

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

- **定义**：加入 Workspace 的链接：token（存 hash）、expires_at、邀请人、预授权角色、目标邮箱（空 = 公开链接）、状态（active/used/revoked/expired）。审计字段：accepted_by（接受人）、accepted_at（接受时间）。Volunteer 可生成链接但不得赋予 Admin 级角色。
- **架构位置**：租户资源；invite_only 空间唯一入口；撤销流程与到期清理已实现（惰性过期检查）。

### JoinRequest（加入申请，租户资源）

- **定义**：request 空间下的加入申请：申请人、Workspace、状态（pending/approved/rejected/expired）；审批通过时分配角色。审计字段：approved_by（审批人）、approved_at（审批时间）、rejection_reason（拒绝原因）、approval_deadline（审批截止时间，默认创建后 7 天）、expired_at（过期时间）。
- **架构位置**：租户资源；审批动作属于高风险管理工具，走确认流。过期转换采用惰性检查（读取时若 pending 且 deadline 已过 → 转 expired）。

### Profile（成员公开资料，租户资源）

- **定义**：头像、简介、技能标签（含 Portfolio 作品展示）per-workspace（ADR-0004，2026-08-08 落地）；`display_name`/`email` 为全局身份字段（不属于 Profile）。主题偏好（ui_theme_preference）同挂 per-workspace。
- **架构位置**：租户资源（WorkspaceProfile，workspace_id + user_id 唯一）；PortfolioItem 同属租户维度（加 workspace_id）。visibility=:workspace 语义 = **目标 workspace 成员可读**（收窄自"任一 workspace"）。
- **默认归属**：默认 workspace "2046"（slug=`2046`，open 策略）——新用户注册自动加入（无差异标签 membership），保证注册即有 profile 编辑上下文；全局 `/settings/account/profile` 入口已下线，redirect 到 `/w/2046/settings/account/profile`。
- 二期需要聚合展示时再拆。

### Event / Course（活动 / 线上课程）

- **定义**：**挂在 Workspace 下**的活动与课程（结构决策，D-A3）：Event 为场地形态（**校园 / 咖啡厅 / 书店 / 联合办公空间**），Course 为线上课程。事件级参与经 **Enrollment**（见下），**不自动成为 Workspace 成员**。
- **架构位置**：租户资源（挂 Workspace）；由 Owner 创建/编辑（单步 CRUD 用表单）；筹备活动/开课程 = 跨角色 workflow；**课程内容 = issue 卡集**（见 Issue 词条，2026-08-16）。

### research_enabled（教研开关，Event-only）

- **定义**：Event 的「本活动不使用教研链路」退出通道（轻聚会等形态），默认 true。**Course 无此开关**（2026-08-16 grill Q12 语义分家）：issue 卡是课程内容本体，Course 恒走教研实例化，`courses.research_enabled` 列已删除——对账规则④对 Course 无条件（open 且无 published 教研定义 = 孤儿），Readiness 教研项对 Course 无条件检查。
- **架构位置**：Event 属性；`ResearchInstantiator.ensure_research_enabled` 门控为 event-only 分支（按 key 前缀分叉）；对账规则④仅 Event 侧保留 research_enabled 过滤。Event 侧 UI 暴露留待真实需求。

### Offering（供给物读取面）

- **定义**：「一行可指向 Event 或 Course」的统一读取 seam = `Cgc2046.Events.Offering`（2026-08-15 读取面收敛，架构评审候选④；plan `docs/plans/2026-08-15-009-offering-read-seam.md` D1-D7 全锁定）。interface：`fetch(kind, id, opts \\ [])`（`{:ok, entity} | {:error, :not_found}`，默认 `authorize?: false`；`actor:` + `authorize?: true` 为 graphql 场景的 actor 感知读取；返回完整 entity 供 status/Readiness 消费）｜`fetch_by_signal_payload(data)`（按 `event_id`/`course_id` 键分派）｜`fetch_titles_by_ids(ids_by_kind, tenant)`（per-kind per-tenant 批量，消 N+1 不退化）｜投影 `kind/1`/`title/1`/`workspace_id/1`。错误形状统一坍缩 `:not_found` 单点。
- **命名空间区分**：kind 原子 `:event` 与 Sponsorship `level: :event`（赞助级别）**撞名但无语义关系**——前者是读取分派键，后者是业务分类字段，勿混用。
- **架构位置**：读取面 seam（events/ 目录）；消费方 = NotificationSubscriber / LearningInstantiator / PendingApprovals / GraphqlSchema（offeringReadiness）/ ResearchInstantiator；不碰 enrollment 裸 SQL 家族、Event/Course lifecycle change、sponsorship level 分叉。

### Issue（学习议题，课程内容原子单元）

- **定义**：Course 内容的原子单元，User-Story 式内容契约：`as_a / given（先修状态）/ goal（目标，Tutor 设定）/ materials（朴素参考列表，无 type 字段——动手卡 ≠ 技能）/ checklist`，带 `kind` 二分——`thoughtwork`（知识型，证据在对话）与 `handwork`（动手型，证据在产物，agent 必须实查产物判完成）。**id 稳定纪律**：issue id 与 checklist item id 发布后不改不删，内容编辑保 id（学习记录永远可追溯）。展示短码 issue key（`PY-02` 式，课程短码-序号，派生非存储）。状态 **Todo / In Progress / Done**（Linear 同款）由学习记录派生——投影非手柄，不提供手动切换。
- **架构位置**：存储于 ResearchOutput(`kind=:issues`)；教研 Agent 起草（Tutor 经 MCP `save_course_content` 活文档式更新，run 终态后仍可改）；读取经 `get_course_content`。取代词汇：section / story 卡 / acceptance / learning_objectives（2026-08-16 课程 issue 学习闭环设计）。

### checklist（检查单）

- **定义**：issue 内可自验条目清单（`{id, text}`，无测试题形态）；handwork 条目指向可检查产物。学习 agent 判定规则：**条目指向产物时必须实际运行/读取产物再判 done，不采信口头完成**；对话类条目经问答自验（checklist 复盘）。
- **架构位置**：issue story 字段组；学习记录按 item_id 追踪。

### 学习记录（LearningRecord，个人记忆库）

- **定义**：一条 checklist 条目的完成记录（done + evidence 摘要 + recorded_at）。**唯一键 `(course_id, user_id, issue_id, item_id)`，upsert 最新为准——记忆挂人不挂报名**（跨 enrollment 延续，退款重报不清零；enrollment_id/run_id 为审计列）。课程 close/cancel 后拒写保读（账本不删）。**记忆在平台、算法在 agent**：平台只存结构与做进度投影（全 issue Done → learning run succeeded），自适应教学决策（八步循环）全在学员 agent，经学习 Agent 指令分发（D10）。导出预留：未来用户可下载个人记忆（用户数据权利）。
- **架构位置**：learning_records 表；MCP `get_learning_records`（course_id 可选，缺省 = 本人全部课程记录）/ `save_learning_records`。

### Enrollment（报名 / 事件级参与者）

- **定义**：Event/Course 的**事件级参与者记录**，归**活动 context**（D-A4）：由报名 workflow **同步调 `create_enrollment` Action** 创建（强一致：名额/唯一性）；**不自动成为 Workspace 成员**。报名轻量表单；免费是默认（Event/Course 不配置定价），收费路径经 Order 缴费（2026-08-15 缴费 grilling 拍板，取代 Learner Q3「全免费」约束）。
- **架构位置**：活动 context 资源；与 WorkspaceMembership（长期成员）两类关系并存。

### 内容安全检查（Content Safety Check）

- **定义**：报名 reason 自由文本的同步内容安全拦截（plan `docs/plans/2026-08-18-009-ugc-content-safety-plan.md`，issue #230；advisor09 F1-F3 修订）。提交时 reason 经微信 **msgSecCheck v2**（`Cgc2046.Miniprogram.Client.content_check/3`，宿主 WechatRequester 直发 `POST /wxa/msg_sec_check`，body `%{content, version: 2, scene: 2, openid}`——SDK `Security.msg_check/2` 为 v1 已废弃）同步检查——**违规内容拒绝提交且不落库**（`result.suggest` 为 `risky`/`review` → BusinessError code `enrollment_content_rejected`）；平台瞬时故障（errcode 非 0 含 45009/47001/61010 / 网络错误 / 非 200）**fail-open 放行**并记 telemetry `[:cgc_2046, :content_check, :skipped]`（metadata 仅类别原子，不含 reason 明文）。
- **范围**：v1 wechat-only——tt/xhs 显式 pass-through（各自平台审核独立，Phase 4 接入）；检查字段仅 `submission_payload.reason`；reason **服务端前置校验**（F3：必须 binary 且 ≤2500 字节合法 UTF-8，违者直接拒绝——检查产物 = 落库产物，无静默截断）。
- **平台判定**：create 时 actor 无 platform（platform claim 在 JWT，User struct 不带），取 `user_identities` 的 wechat uid 作 openid（order.ex 同款 SQL）——有 wechat identity → wechat 检查；无 wechat identity（tt/xhs 单平台 / web 无 identity）/ 查询失败 → pass-through 放行。
- **红线**：reason 明文不进日志 / telemetry / BusinessError message；msg_check 请求走宿主 WechatRequester（debug: false 既有）。
- **架构位置**：`Client.content_check/3`（miniprogram facade，v2 错误分类单点）+ `Enrollment :create_enrollment` 的 before_action **首位**（F2：外呼移至目标校验 / FOR SHARE 行锁获取之前，外呼不持锁）；前端文案在 `miniprogram/src/domain/error-copy.ts`（`enrollment_content_rejected`）。

### learning 锚定（Enrollment Anchor）

- **定义**：「learning run 锚定到哪条 Enrollment」的**唯一读取真源** = `Cgc2046.Events.Enrollment.anchor/1`（+ 双键提取 `anchored_id/1`；2026-08-17 架构深化 E，plan `docs/plans/2026-08-17-004-learning-anchor-claim-guard.md` D1-D8 全锁定）。三消费方（Workflows→Events 依赖方向）：`StepAuthorization.enrolled_learner?`（fail-closed→false）/ `LearningInstantiator`（instantiate + ensure_create_guards + instance_key/input_enrollment_id，warning+:ok）/ `LearningProgressWorker`（fetch_enrollment_or_nil→nil / remind_stagnant→:skipped）——三份私有拷贝已收编于此，删则复杂度回散三处。
- **双键超集语义**：string 键优先、atom 键兜底（`Map.get(m, "enrollment_id") || Map.get(m, :enrollment_id)`）——可达输入全为 string 键（input_snapshot 经 JSONB 持久化；唯一写入方 LI 以 string 键构造 input），atom 分支仅激活于不可达的 in-memory 输入（安全方向，fail-closed 不放松）。
- **双错误语义**：无锚 → `:no_enrollment_anchor`（含 nil 防御 input_snapshot 可空）；有锚读取失败/不存在 → `:enrollment_read_failed`（避开 payments 域同名 `:enrollment_not_found`，防跨域误读）。错误原子零外部消费，仅进日志与 with 通配符。
- **边界不收**：reconciliation_scan_worker ×2、graphql ×2（anchored_to_enrollment? SQL filter / 展示投影）、ActorIsEnrolledLearner（委托非拷贝）、payments 域。
- **配套（G）**：SignalSubscriber 骨架把 `:claim_in_handle` 策略结构化为**双回调**——`before_claim/2`（校验链 → `{:ok, ctx}` | `:skip` | `{:error,_}`）+ `effects/3`（副作用），claim 时机由骨架持有（before_claim 后、effects 前），不再依赖模块自调；`:skip`/`{:error,_}` 不烧 claim 归一化 `:ok`（重投仍可推进），重复投递 `:duplicate` → `:ok`（不重复执行 effects），声明策略但未实现双回调 → `raise ArgumentError`。历史 post-hoc 检测方案因无法区分「校验不过合法 skip」与「忘调 claim」被证伪，弃用。
- **架构位置**：事件 context 资源（events/）读取面；依赖方向 Workflows→Events，三消费方坍缩语义各自保持。

### PriceTier（价格档位）

- **定义**：收费 Event/Course 的嵌入式定价配置（`pricing_enabled: true` 时的 `price_tiers` 字段），形状：id / name / amount_cents / available_until。金额下限 **1 分，无 0 元档**（免费场景 = `pricing_enabled: false` 整场免费，或管理员免缴个例）；`available_until` 到期档位报名时自动隐藏。下单即快照（tier_snapshot + amount_cents），改价/删档不追溯已生成订单。
- **架构位置**：Event/Course 属性（先例：`sponsorship_tiers` 嵌入式无独立表）；与 SponsorshipTier 刻意成对但语义对立——本词条是真实收款金额，后者仅登记意向（见 §9）。

### Order（缴费订单，租户资源）

- **定义**：一笔报名的缴费单，归属 **Payments domain**（`payments_orders` 表），资金事实源。持渠道关联键（`out_trade_no` 我方单号 / `transaction_id` 渠道单号）、tier 快照与金额（**分**）、provider（wechat_jsapi / wechat_native / alipay_page / alipay_wap）、状态机 `pending → paid → refunding → refunded`（`refunding → refund_failed` 渠道拒绝，`refund_failed → refunding` 经 retry_refund 重入；cancelled / expired 为终态）。不变量：一个 Enrollment **至多一个非终态 Order**（部分唯一索引）；回调金额必须等于订单金额。**退款即取消报名**：全额退款同时取消 Enrollment 并释放名额（ADR-0007）；订单过期后渠道侧迟到扣款自动原路退回。
- **组织者查询面（organizer-payment U4/U7）**：Order 计算字段 `event_id` / `course_id`（expr(enrollment.event_id)，Enrollment 无 GraphQL 对象类型的惯用替代）使 `workspaceOrders` 可按活动筛选；`workspacePaymentStats` 收可选 `eventId`/`courseId`（JOIN enrollments 收敛，四数口径同源）；`retryRefund` mutation 暴露给客户端（此前只有后端 action）。活动经营面（详情页 OfferingPaymentsPanel，manage_events 门控）与工作区财务面（收款管理页 + 活动筛选）两层结构：定价与订单随活动走，工作区级只留汇总。孤儿定价配置页（/settings/pricing）已删除，TierEditor 共享组件嵌入创建/编辑表单。

### 管理员免缴（Fee Waiver）

- **定义**：Owner/Admin 将 `payment_pending` 报名直接置 `confirmed` 的特权操作，跳过支付、不建订单；个案级免费入口（志愿者/组织者参会），审计照走。区别于 `pricing_enabled: false`（整场免费）与 0 元档（不存在，PriceTier 金额下限 1 分）。
- **关闭收费批量转换（organizer-payment U3/R9）**：Event/Course update 检测 `pricing_enabled` true→false 时，同事务对该活动全部 `payment_pending` 报名逐条复用免缴三元组（CAS 转确认 + 作废待付单 + 免缴审计行）+ 补发 completed 信号（`Enrollment.waive_pending_for_offering/4`，经 `Changes.WaivePendingOnPricingDisable` 挂接）。落账竞态 CAS 先到先得（先落账者保持已付）；迟到扣款由落账 worker 按免缴审计行/作废单判定自动原路退回——审计行不可省（KTD4 正确性约束）。

### Sponsorship（赞助，两级）

- **定义**：**两级赞助** = Event 级（单场活动）+ Workspace 级（长期）（D-A3）。赞助方以账号身份参与赞助 workflow（意向 → Owner/Admin 审批 → 权益生效），**不必成为成员**。
- **架构位置**：活动/Workspace 资源；权益生效经异步 Signal。

### 赞助审批人（Sponsorship Approver Roles）

- **定义**：「谁是赞助审批人」规则（拍板 #4）的唯一真源 = `Cgc2046.Policies.SponsorshipApprover.approver_roles/1`（2026-08-17 架构深化候选 F，plan `docs/plans/2026-08-17-002-sponsorship-approver-roles.md` D1-D8 全锁定）：`approver_roles(:event) -> Role.manage_roles()`（owner/admin，角色清单变更自动跟随）｜`approver_roles(:workspace) -> [:owner]`（长期承诺加严；平台 Admin 备案二期，不参与审批）。**三消费面只改此处即全链路跟随**：写面 `match?/3`（approve/reject policy，委托 `Enum.any?(roles, &(&1 in approver_roles(level)))`）｜提醒面 `ApprovalReminderWorker` 每工作台两套收件人选择器按 `{:roles, approver_roles(level)}` 派生（收件人零变化，测试钉死）｜读面 `PendingApprovals` 按角色集反查 `allowed_levels` 做 Sponsorship 行级过滤（`level in ^allowed_levels` 下推到 pending/expired/count 三路径——admin 无 workspace 级行，与写面 policy 一致，看得到点不动的行不进待办读面）。
- **架构位置**：横切判定面（policy 模块内纯函数薄壳，规则归属地不另起第二真源）；消费方 = sponsorship approve/reject policy / ApprovalReminderWorker / PendingApprovals；`is_nil(event_id)` 不变量本体不动（仅 ARW 不再作分派依据）。

### SpeakerInvitation（分享嘉宾邀请）

- **定义**：**Event 级邀请**（D-A3）：Owner 创建 → 邀请 workflow（接受/拒绝 → 分享材料产出 → 结束）；分享完**关系结束**，不成为成员。
- **架构位置**：活动 context 资源；邀请/接受状态由 Signal 驱动。

### ShareScheme（微信 URL Scheme 分享链接）

- **定义**：微信分享深链缓存的存储/复用面（plan 011，spike D1-A/D2-A 拍板）：`miniprogram_share_schemes` 表（全局资源，GlobalApi domain，无 GraphQL 面），UK `(target_kind, target_id, platform)`——同一目标/平台只留一份 scheme，未过期命中**复用零外呼**、过期重生成 upsert 覆盖（照 `Miniprogram.Code` 先例）。到期失效 = `min(registration_deadline + 7d, now + 30d)`，deadline 缺失 → `now + 30d`（30 天为官方临时 scheme 硬上限；时间源经 plan owner 2026-08-18 应答修正：Event/Course 均无 endsAt，统一以 registration_deadline 为 clamp 代理）。
- **架构位置**：生成/复用/clamp 唯一入口 = `Cgc2046.Miniprogram.ShareSchemeService.fetch_or_generate/2`（外呼经 `UrlScheme.create_link/3`，errcode 保真传播不落库）；触发 = `Workflows.ShareSchemeInstantiator` 订阅 `event.launched`/`course.launched` → Oban job（`Workers.ShareSchemeWorker`，maintenance 队列）异步预生成——外呼不进信号同步路径，`:not_found` warning 不重试、平台错误走 Oban 默认重试。scheme query/path 只含 `id`+`kind`（安全红线，永不携带 token/凭据/openid）；前端配套 = event-detail 分享 title 兜底 + `Taro.onAppShow` 热启动路由（`resolveAppShowRoute` 纯函数，scene 优先）。

### AuditLog（审计日志，二期）

- **定义**：敏感操作留痕的全局日志（二期接 `ash_paper_trail`）；一期以 ToolCallLog 每次工具调用审计记录覆盖。
- **架构位置**：二期基础设施。

### 通知分发面（Notification Fanout）

- **定义**：**收件人解析 + 通知入队的唯一归属**（2026-08-14 通知分发收敛，架构评审候选①，依赖异步链路 PR-B 合入后落地）。interface 三件套：`managers(workspace_id, selector)`（租户内目标角色成员 → `%{user_id => [identity]}` 平台身份分组）｜`identities(user_id)`（单用户全平台身份）｜`deliver(recipients, template_key, data, job_meta, unique)`（入队 args 形状 / identity_uid 展开 / unique 预设的唯一实现）。**收件人选择器是数据不是谓词**：`:manage`（走 `Role.manage_roles/0` 唯一真源）｜`{:roles, [...]}`（显式窄集，如赞助 Workspace 级仅 Owner，拍板 #4）；unique 用命名预设 `:default`｜`:reminder_7d`，未显式传参时按 template_key 查 `NotificationWorker.type/1` 的 unique 预设（缺省 `:default`，2026-08-18 架构深化候选 D D3）——Oban unique 语义不进 interface。**错误内化**：不崩、必 Logger + telemetry（`[:cgc2046, :notification_fanout, :deliver]`，失败可计数）。
- **架构位置**：NotificationSubscriber / SpeakerSubscriber（handle 体）与 ApprovalReminderWorker / LearningProgressWorker（按工作台预取分组复用，消 N+1——两段式 interface 的原因）四方调用的 seam；NotificationSubscriber 退化纯订阅方（公共入队面删除，异步计划 Q4 backlog 落地）；发送侧 NotificationService 与 NotificationWorker 不动；`target_title` 的 Event/Course 分叉不在此面（属 offering seam 候选）。

### 通知类型（Notification Types）

- **定义**：**通知类型契约的唯一真源** = `Cgc2046.Workers.NotificationWorker` 的 `@notification_types` 表（2026-08-18 架构深化候选 D，plan `docs/plans/2026-08-18-005-notification-type-registry.md` D1-D8 全锁定；AEW `@expiry_specs` 同款声明式规格先例），公开 `type/1`（按 template_key 查条目 \| nil）与 `types/0`（全条目）读契约。条目字段：`template_key`（通知类型键，与 config `:miniprogram_templates` 三平台 registry 键集**双射**；runtime.exs prod 块同键集注入亦由 D7 测试锚定——三面一致，防 prod 漏配静默失败）｜`id_key`（stale 重查的资源 id 在 data 中的键，无重查 = nil）｜`data_keys` / `job_meta_keys`（生产方构建 data / job_meta 的键集契约）｜`unique`（NotificationFanout.deliver 缺省 unique 预设 `:default` \| `:reminder_7d`）｜`stale`（重查规格 `{resource, required_status, :not_expired \| :running}`，nil = 不重查）。
- **stale 语义（表驱动单解释器，D2）**：提醒类类型发送时重查——approval_reminder 同键两行（Enrollment / Sponsorship 面，由 data 携带的 id_key 分派）走 `ApprovalDeadline.not_expired?/2` **放行谓词**（nil 永不过期=投递、==now 不放行=跳过；**禁用 overdue?/2**——不对称对偶）；learning_stagnation 走 WorkflowRun `status == :running`。非 required_status / 读失败 → 跳过（stale=true）；未知类型 / 无 stale → 不重查直接投递。
- **收敛/不收边界**：收敛面 = 键集契约（data_keys / job_meta_keys）+ unique 预设 + stale 谓词（D4）；payload 值构建不收敛（生产方仍自构建 data / job_meta 值，D4/D6——`Payments.NotificationTemplates.payment_data/1` 是唯一 payload builder 先例，不扩此面）；NotificationFanout 主体 / NotificationService / Miniprogram.Client / config 面与 miniprogram SubscriptionScenario（独立数据面，`event_reminder` 漂移仅 advisory，D5）不收。
- **架构位置**：横切契约面（root Worker 单文件，AEW `@expiry_specs` 同款先例）；消费方 = NotificationFanout（unique 缺省查表，D3）/ 生产方（moduledoc 契约描述引用 `type/1`，D6）/ 表驱动契约测试（`test/cgc_2046/workers/notification_worker_test.exs`，D7）。
- **缴费闭环新增键（organizer-payment U5，R12/R13）**：`payment_received`（收款到账 → workspace 管理者逐笔实时感知，data 含 title/tier_name/amount；落账 worker 挂点）与 `payment_expired`（订单超时 → 学员 + 管理者，data 携带 `re_enrollable` 标志——报名截止未过才承诺可重新报名；过期 worker 成功分支挂点，尽力而为不影响释放）。推送尽力而为，可靠兜底 = 经营面面板；模板未配置时 provider_not_configured 静默跳过。

### 审批期限（Approval Deadline）

- **定义**：审批截止时间的派生语义唯一真源 = `Cgc2046.ApprovalDeadline`（2026-08-14 审批期限深化，架构评审候选②；plan `docs/plans/2026-08-14-005-approval-deadline-deepening.md` D1-D8 全锁定；2026-08-17 架构深化 A+B 补谓词端口 `not_expired?/2`，plan `docs/plans/2026-08-17-001-approval-claim-predicate-port.md` D7-D8 全锁定）。interface：`derive/1`（列实体读 `approval_deadline` 列；Invitation 读 `expires_at` 列；WorkflowRun = `updated_at + definition.approval_timeout` 内存派生，调用方需先 load definition）｜`not_expired?/2`（**放行谓词**：nil→true、否则严格 `> now`；==now 不放行）｜`overdue?/2`（**扫中谓词**：deadline 严格过点 `< now`）｜`in_window?/3`（提醒窗口 `(now, window_end]` 半开区间）｜`default_timeout_days/0`（四资源创建期默认期限 7 天的唯一来源）。`not_expired?` 与 `overdue?` 是**不对称对偶**（nil 侧相反：not_expired? nil→true / overdue? nil→false；==now 侧双双 false），语义分工：放行谓词（claim 守卫 / 投递守卫）vs 扫中谓词（过期扫描），不可互相代用；SQL 端口 = ApprovalClaim 的 deadline 守卫（`:future` ↔ not_expired? / `:passed` ↔ overdue?，测试对偶钉死）。
- **nil 语义（单点）**：`derive/1` 返回 nil = **永不过期**——不参与过期扫描（`overdue?` 恒 false），也不进入提醒窗口。WorkflowRun 的 `definition.approval_timeout = nil`（F7 方案 A）即此语义；列实体 deadline 列为空同此。
- **扫尾 specs**：ApprovalExpiryWorker 六份过期扫描由 `@expiry_specs` 声明式规格驱动（`{resource, status, deadline: {:column, atom} | :derived, tenant}`）——列实体保持 SQL 下推过滤，WorkflowRun 走 `:derived`（load definition + 内存判断，**绝不可并入纯 SQL 分支**，否则 timeout nil 的 run 会被误扫）；每记录转换仍走各资源 `:expire` 领域 action（D-A6）。
- **架构位置**：横切读取面（root 单文件，NotificationFanout 同款先例）；消费方 = ApprovalExpiryWorker / ApprovalReminderWorker（窗口大小 48h 仍为 ARW 私有常量）与四资源创建期（Enrollment 客户端可传覆盖 / Sponsorship 服务端固定的创建纪律差异另行决策）。

### 原子抢占（Approval Claim）

- **定义**：条件 UPDATE 原子抢占唯一真源 = `Cgc2046.ApprovalClaim`（2026-08-17 架构深化候选 A+B，plan `docs/plans/2026-08-17-001-approval-claim-predicate-port.md` D1-D10 全锁定；评审 `docs/reviews/architecture-review-2026-08-16.html` 候选 A）。interface：`claim(record, opts)`——`table:`（编译期枚举 atoms，拒绝任意字符串）｜`from:`（状态守卫数组，`status IN (...)`）｜`set:`（列 → 字面值 | `{:arg, atom}` | `{:sql, fragment}`）｜`deadline:`（`{col, :future | :passed}`；`:future` → `(col IS NULL OR col > $N)`，`:passed` → `col IS NOT NULL AND col < $N`；守卫复用 set 中 `{:arg, :now}` 占位符，SQL 端口 = ApprovalDeadline.not_expired?/overdue?）｜`extra_where:`（`{sql_fragment, params}`，片段占位符 `$1` 起内部编号、claim 统一重编号到全语句连续编号——42P18 纪律单点化）｜`returning:`（列原子列表，成功回读 DB 原始值）。占位符序：SET 值 → extra_where 参数 → id（固定最后一个参数）。
- **错误分工（D3）**：claim 只返回 `{:ok, returned} | {:error, :not_claimed}`，DB 错误 `{:error, {:database, reason}}` 回传资源层——各资源现有错误原子/消息/发生层原样保留（graphql 契约字符串、Splode code、域错误原子均不动）；sponsorship 读回消歧（approval_conflict/reject_conflict）、enrollment claim_cancellable RETURNING 值判读留各资源。
- **收编边界**：7 资源 14 条 claim SQL（join_request/workspace_application approve、invitation accept、enrollment claim_pending/prepare_expire/claim_cancellable/claim_waive、sponsorship approve/reject/expire/end、speaker_invitation claim_decision×2/claim_complete）。**保留（D5）**：invitation accept_miniprogram（多表 JOIN+别名+双 deadline 列）、user demote（count 子查询聚合）、enrollment reserve/consume/release counter、validate_pending_status 快照守卫×2、transition.ex、payments/order.ex 私有 claim/4、其余非 approval deadline 守卫（registration_deadline/invite_batches/sponsorship_deadline + FOR SHARE）、Ash expr 全部（ARW/AEW/pending_approvals/reconciliation，D7 冻结面）。
- **组合序留在资源层**：sponsorship approve 独占位 advisory lock（`Repo.acquire_lock!`）在 claim 前取得（锁序 lock→claim，D6）；不加租户过滤（row id 已从租户隔离读面解析）；不自己开事务/checkout（before_action 事务继承，savepoint 语义不变）；成功不 force_change（回写留资源层）。plan 2026-08-15-010 D4「裸 SQL 本体不动」re-scope：claim 族是真同构（deletion test 失败=复杂度随资源数扩散），与 domain_error 族假同构（39 原子仅 1 共享）区分。
- **架构位置**：横切写原语（root 单文件，ApprovalDeadline / NotificationFanout 同款先例）；消费方 = 七个资源 action 的 before_action（事务内）+ 表驱动契约测试（`test/cgc_2046/approval_claim_test.exs`）。

### 对账扫描（Reconciliation Scan）

- **定义**：平台级 best-effort 异步路径孤儿报告（E-10 #125；plan `docs/plans/2026-08-15-011-e10-reconciliation-scan.md` D1-D10 全锁定）。`ReconciliationScanWorker` 每 10 分钟扫六规则 → 落 `Reconciliation.Finding`（表 reconciliation_findings，全局资源，read 仅 PlatformAdmin）→ /admin/reconciliation 对账页可读。
- **六规则**：① confirmed enrollment 无 learning run（`workflow_runs.input_snapshot->>'enrollment_id'` join `workflow_definitions.type=learning`，BYO 无平台终态、存在即非孤儿）｜② pending 无 approval_deadline（enrollment/sponsorship/join_request/workspace_application 四资源 UNION，创建路径必写）｜③ active sponsorship 的 `sponsorship.active` 发布 job 处于 discarded（PR-A 同事务必入队，死信=信号链断连；原「无 signal_log」因 ADR-0003 入向局限不可实现而修正）｜④ open 但工作台无 published 教研定义——Course 无条件命中（research_enabled 已删列，2026-08-16 Q12）、Event 仅 research_enabled=true 命中（false = 轻聚会合法不命中）｜⑤ closed/cancelled Event/Course 仍有非终态 research run（instance key `event_<id>`/`course_<id>`，reaper 同约定）｜⑥ 信号族死信（SignalPublishWorker / NotificationWorker 的 discarded job）。
- **刷新语义**：命中 upsert（唯一键 `(rule, entity_type, entity_id)`，保 first_seen_at、刷新 last_seen_at），本次未命中删除——「无孤儿 → 空报告」由结构保证。
- **死信窗口**：规⑥只判 oban_jobs 7 天窗口内（与 Oban Pruner max_age 对齐）的 discarded 行；死信可见性由本扫描承担，不扩 Oban discard 插件。
- **七天上限（窗口语义，非 bug）**：规③/规⑥的有效窗口同受 Oban Pruner（max_age 7 天）约束——discarded job 被 Pruner 删除后，未消解的规③/规⑥孤儿会从报告静默消失（刷新语义按未命中删除，视为已消解）。
- **缴费对账（预留）**：Order 落地后扩规⑦——夜间拉渠道账单（微信/支付宝对账单 API）核对 paid 订单（渠道侧无对应交易 / 金额不符 / 我方 pending 超期未清），差异同落 `Finding`（ADR-0007，webhook 丢失的长尾兜底）。
- **架构位置**：`Cgc2046.Reconciliation.Finding`（Api domain 全局资源）+ `Cgc2046.Workers.ReconciliationScanWorker`（maintenance 队列，unique 300s，规1/2/4/5 Ash 查询下推、规3/6 Repo 直查 oban_jobs）；配套 SignalSubscriber 骨架 telemetry `[:cgc2046, :signal, :deliver]`（D7）与订阅方冒烟测试（#134-①）。

### 工具 = 形状 原则（见 §3）

---

## 9. 术语使用约定与易混清单

| 易混对 | 区别 |
| --- | --- |
| 登录 Token vs 连接 token | 登录 Token：网站 UI 的 httpOnly cookie（JWT）；连接 token：MCP `Authorization: Bearer` 头，绑用户不绑工作区 |
| A 通道 vs B 通道 | A 通道（网站派活）已删除；B 通道（网站 MCP server）是唯一主干 |
| Agent vs AgentRun | Agent 是授权/配置登记（不含执行，实体系 roadmap）；AgentRun 是 ToolCallLog 的聚合投影概念（实体不建，随 Agent 落地重启） |
| 个人 Agent vs 公共 Agent | 个人 = 角色分身仅本人可见；公共 = Workspace 级按 Workflow 协作 |
| Skill vs Agent | Skill 是预设工作流（SKILL.md）；Agent 是带人格/面板/技能绑定的助手；工作区 Skill 经本地同步进 `~/.clacky/skills/` |
| `cgc-2046` vs `cgc2046-<ws>-<skill>` | `cgc-2046` 是扩展 id / MCP 条目名；`cgc2046-<ws>-<skill>` 是本地同步技能的命名前缀 |
| 确认流 vs 直接执行 | 高风险管理工具必须 pending → `confirm_operation` 才落库（two-tool 模式）；低风险写工具（save_* 族）直接执行 |
| PriceTier vs SponsorshipTier | PriceTier 是真实收款定价（收款即发生）；SponsorshipTier 是赞助意向档位（v1 仅登记不收款，amount_suggestion） |
| WorkflowDefinition vs WorkflowRun | 蓝图（Runic.Workflow DAG + 版本）vs 执行实例（pending→running→waiting→succeeded/failed/cancelled，归属 partition） |
| 同步写 vs 异步 Signal | 业务核心状态主写入口走同步 Ash Action（强一致，8）；衍生副作用/通知走 Signal 异步最终一致（2） |

## 10. 待细化/待办（编码阶段）

- ~~Invitation 撤销流程（revoked 状态 + 到期清理）~~ ✅ 已实现（slice-B）
- ~~JoinRequest 审批的角色分配方式（申请人请求 vs 审批方指定）~~ ✅ 已定稿：审批方指定（slice-B 决策 2）
- 确认流 auto_approve 模式的冷却期（二期）
- 平台管理员建 Workspace 的审计留痕
- 人工步骤超时/取消语义（workflow `waiting` 状态：如报名截止后取消 run）
- 异步 Signal 路径的幂等键与重试策略（v1 设计阶段）
- `docs/01-定稿设计/领域模型定稿.md` 同步 workflow 引擎概念（WorkflowDefinition/WorkflowRun/Step 四分类/partition/Thread journal/Enrollment/Sponsorship/SpeakerInvitation）
