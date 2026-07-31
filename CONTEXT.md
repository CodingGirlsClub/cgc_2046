# CGC 平台领域术语表（CONTEXT.md）

> **单一事实源**：本文件是 CGC 平台全部领域术语的权威出处。代码、文档、Issue、测试命名一律使用本表词汇，不引入同义词。
> 日期：2026-08-01 ｜ 维护：领域建模工程师 ｜ 依据：`docs/领域模型定稿.md`（2026-07-31）+ `docs/grill-决策记录-2026-08-01.md`（D1–D14）
> 状态：**已整合 BYO/MCP 时代术语**（D1–D14 决策全量落盘）

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
- **定义**：用户侧 OpenClacky 的官方扩展，id/名称统一为 `cgc-2046`；安装后提供 CGC 助手、本地 Skill 同步、MCP 连接读取等能力（D14）。
- **架构位置**：用户侧入口。`openclacky ext install <zip URL>` 安装（D13 步骤 3）；扩展自动读 `mcp.json` 的 cgc 条目获取 URL + token，零额外配置（D13）。

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
- **定义**：租户单元。UUID 主键 + 全局唯一 slug（展示用），带加入策略 `join_policy`（open | request | invite_only）。由平台管理员创建并指定 Owner，普通用户不可自助创建。
- **架构位置**：全局资源；所有租户资源以 `workspace_id` 列过滤（Ash attribute 多租户策略）。

### join_policy（加入策略）
- **定义**：Workspace 的三种加入方式：`open`（公开可发现、直接加入、无需审批）、`request`（公开可发现、申请后审批）、`invite_only`（私密、仅邀请链接可加入）。
- **架构位置**：Workspace 属性，Owner 可设置；驱动 Invitation / JoinRequest 行为。

### WorkspaceMembership（成员关系，租户资源）
- **定义**：1 条/人/租户的成员记录（user_id + workspace_id + 加入时间 + 邀请人）。
- **架构位置**：成员身份的事实来源；授权链第 2 步"定位身份"读它。

### MembershipRole（成员角色关联，租户资源）
- **定义**：membership ↔ Role 的 N:M 关联表。一人多角色由此表达。
- **架构位置**：权限判定时"所有角色权限取并集"的数据基础。

### Role（角色，租户资源）
- **定义**：租户内可扩展实体（非写死枚举），权限挂在角色上。默认模板：Owner / Admin / Tutor / Volunteer / Learner。
- **架构位置**：RBAC 核心；Step/Agent 上存 `role_id` 引用。

### 平台管理员（Platform Admin）
- **定义**：全局标记（`is_platform_admin`，非租户角色），可多人；负责创建 Workspace 并指定 Owner。
- **架构位置**：User 上的布尔标记，跨租户生效。

### 连接 token（MCP 连接令牌 / Connection Token）
- **定义**：每用户一个的 MCP 认证凭证。**绑用户、不绑工作区**；可访问用户加入的多个 Workspace，具体租户由每次调用的目标资源（workspace_id）判定（D6/D13）。在网站"连接设置"页生成。
- **架构位置**：MCP server 的 `Authorization: Bearer <token>` 头；`mcp.json` 是它的单一配置点。**区别于网站登录 Token**：登录 Token 是 httpOnly cookie，只用于网站 UI。
- ⚠️ 注意：本术语**取代**更早调研文档（`docs/OpenClacky扩展调研与实施计划.md` §3.4）中"token 绑 workspace_id"的旧设计——D13 定稿为绑用户不绑工作区。

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

### 审计记录（Audit Record）
- **定义**：每次 MCP 工具调用（谁/工具/参数/结果/确认/时间）的结构化记录；"无确认不落库"的写操作在确认后落库并审计。
- **架构位置**：AgentRun 的数据基础（见 §5）；二期可接 `ash_paper_trail` 增强。

---

## 4. Workflow 执行模型

### Workflow（工作流，租户资源）
- **定义**：由多个 Step 组成的教研/协作流程；用状态机管理（草稿 → 发布 → 归档）。构建不做可视化 UI，经 OpenClacky 的构建器 Agent/Skill 产出 DSL 后部署。
- **架构位置**：租户资源；部署权限 Owner/Admin/Tutor。

### Step（步骤，租户资源）
- **定义**：Workflow 的最小授权单元，声明执行角色集合 + 使用的 Agent；带顺序解锁（Step 1 完成才能执行 Step 2）。
- **架构位置**：租户资源；`STEP_ROLE` 关联表授权；AgentRun 按 Step 聚合。

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
- **定义**：用户接入平台的引导流程（D13）：
  1. **装 OpenClacky**（网站给安装命令）
  2. **添加 MCP 连接**（粘贴 mcp.json 片段：`{type: http, url: https://cgc.example.com/mcp, headers: {Authorization: Bearer <token>}}`；token 在网站"连接设置"生成，绑用户不绑工作区）
  3. **安装连接器扩展**：`openclacky ext install <zip URL>`
- **架构位置**：新用户接入路径；加入新工作区无需重新配置（token 通用，scope 靠 workspace_id）。

### mcp.json（单一配置点）
- **定义**：OpenClacky 的 MCP 配置文件；扩展自动读其中 cgc 条目拿 URL + token，零额外配置（D13）。
- **架构位置**：用户侧连接配置唯一事实源。**不做"一条命令全自动"**——扩展不代写 mcp.json，避免被覆盖。

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

### Event / Course（插件占位）
- **定义**：二期插件占位实体，不入 ER。
- **架构位置**：预留扩展点。

### AuditLog（审计日志，二期）
- **定义**：敏感操作留痕的全局日志（二期接 `ash_paper_trail`）；一期以 AgentRun + 每次工具调用审计记录覆盖。
- **架构位置**：二期基础设施。

### 工具 = 形状 原则（见 §3）

---

## 9. 术语使用约定与易混清单

| 易混对 | 区别 |
|---|---|
| 登录 Token vs 连接 token | 登录 Token：网站 UI 的 httpOnly cookie（JWT）；连接 token：MCP `Authorization: Bearer` 头，绑用户不绑工作区 |
| A 通道 vs B 通道 | A 通道（网站派活）已删除；B 通道（网站 MCP server）是唯一主干 |
| Agent vs AgentRun | Agent 是授权/配置登记（不含执行）；AgentRun 是网站按 MCP 工具调用自动聚合的领域操作记录 |
| 个人 Agent vs 公共 Agent | 个人 = 角色分身仅本人可见；公共 = Workspace 级按 Workflow 协作 |
| Skill vs Agent | Skill 是预设工作流（SKILL.md）；Agent 是带人格/面板/技能绑定的助手；工作区 Skill 经本地同步进 `~/.clacky/skills/` |
| `cgc-2046` vs `cgc2046-<ws>-<skill>` | `cgc-2046` 是扩展 id / MCP 条目名；`cgc2046-<ws>-<skill>` 是本地同步技能的命名前缀 |
| 确认流 vs 直接执行 | 高风险管理工具必须 pending → request_user_feedback → confirm 才落库；低风险工具（create_agent/create_workflow）直接执行 |

## 10. 待细化/待办（编码阶段）

- Invitation 撤销流程（revoked 状态 + 到期清理）
- JoinRequest 审批的角色分配方式（申请人请求 vs 审批方指定）
- AgentRun 的 token 用量字段（tokens_in/tokens_out）为计费留底
- 确认流 auto_approve 模式的冷却期（二期）
- 平台管理员建 Workspace 的审计留痕
