# CGC 平台核心(M0–M4)与 OpenClacky 对接 — Platform Spec

> 状态:`ready-for-agent` · 日期:2026-07-31(v0.2 架构修订:AI 执行移至本地,平台无 LLM)
> 输入文档:docs/领域模型定稿.md、docs/用户旅程与Web功能清单.md、docs/技术调研与实施计划.md、docs/OpenClacky扩展调研与实施计划.md、docs/ash-authentication-token-调研.md、docs/deploy-api-rest-vs-graphql-调研.md
> 词汇表:Workspace(Club)、Role、Step(授权最小单元)、agent_hint(Step 提示文本,指向本地 Agent)、MembershipRole、JoinRequest、Invitation

---

## Problem Statement

CGC(Coding Girls Club)要把线下"编程女孩日"教研活动产品化为一个平台:教练/志愿者/学员在 Workspace 里协作,通过 Workflow 完成教研活动(大纲设计 → 招募物料 → 练习答疑)。但:

- **权限太关键**:志愿者不该部署 Workflow;学员不该看到/执行没授权给她的 Step;跨租户资源绝不能泄漏。现有方案没有任何软件系统管这件事。
- **AI 在用户本地**:所有 AI 能力(Agent、对话、执行)都由用户本地的 OpenClacky 承担——平台**不做任何 LLM/Agent 执行**,只做业务逻辑与严格授权。平台必须让"用户经本地 AI 发起的一切操作"和"网站上的操作"遵守**同一套严格授权**——否则自建 Skill 就能绕过权限。
- **从零起步**:backend(Phoenix+Ash 脚手架)与 web(Next.js 脚手架)都是空壳,没有业务代码、没有测试基建、没有部署。

## Solution

一个纯业务逻辑的多租户平台 + 一个承载全部 AI 能力的 OpenClacky 官方扩展:

- **租户 = Workspace**:共享表 + `workspace_id` 隔离;一人多 Workspace;加入策略三态(open/request/invite_only);平台管理员创建 Workspace 并指定 Owner。
- **RBAC 可扩展**:Role 是租户内数据库实体(非写死枚举),默认模板 Owner/Admin/Tutor/Volunteer/Learner;一人多角色取权限并集;**Step 是授权最小单元**——每个 Step 声明可执行角色与 agent_hint,学员只能看到/执行自己角色允许的 Step。
- **平台 = 业务逻辑**:认证、多租户、RBAC、Workflow/Step 编排与状态机、加入流程、ApiToken、审计。**无 LLM、无 Agent 执行、无流式对话**。
- **AI = 本地 OpenClacky**:所有用户(含学习者)通过本地 OpenClacky 与平台交互;CGC 扩展承载官方 Agent(教研助手/活动筹备)、个人 Agent 构建、Step 执行——本地完成后经 cgc-bridge 把状态回传平台推进状态机。
- **严格授权链**:平台永不信任客户端——token 只是身份凭证,权限每次请求实时计算(认证→成员关系→RBAC→资源/Step 级→审计)。OpenClacky 扩展、用户自建 Skill、网站 UI 走同一判定,越权一律 403。
- **API 双轨**:REST `/api/v1/*` 给 OpenClacky(主入口),GraphQL 给网站;两壳共享同一批 Ash action 与同一套认证/授权。

## User Stories

### 平台管理员(Platform Admin)

1. As a platform admin, I want to log in and reach a platform admin area, so that I can manage workspaces.
2. As a platform admin, I want to create a Workspace (slug, name, join policy) and designate its Owner, so that a club can start operating without self-signup chaos.
3. As a platform admin, I want to prevent ordinary users from creating Workspaces, so that only curated clubs exist.

### 所有用户(全局账号)

4. As a visitor, I want to register with email and password, so that I can use the platform with one global account.
5. As a registered user, I want to log in and stay logged in, so that I don't re-authenticate on every page.
6. As a visitor, I want to browse a public Club discovery page listing open/request workspaces, so that I can find clubs to join.
7. As a visitor, I want to view a Club public page (name, intro, member count), so that I can decide whether to join.
8. As a user, I want to join an `open` workspace directly and get the default Learner role, so that joining is frictionless.
9. As a user, I want to submit a join request to a `request` workspace, so that the Owner/Admin can approve me.
10. As a user, I want to join via an invitation link (slug + last-4 UUID, validated, preview page, optional pre-authorized role), so that invite-only clubs can onboard me.
11. As a user, I want a workspace switcher listing my Workspaces, so that I can enter the one I want to work in.
12. As a platform admin, I want an admin console entry in the switcher, so that I can reach workspace creation.

### Owner

13. As an Owner, I want to set or change the Workspace join policy (open/request/invite_only), so that I control how people enter.
14. As an Owner, I want to manage members (list, grant roles, remove), so that membership stays correct.
15. As an Owner, I want to approve or reject join requests, so that `request` workspaces stay safe.
16. As an Owner, I want to generate invitation links with optional pre-authorized roles, expiry and target email, so that I can onboard people with the right roles.
17. As an Owner, I want to revoke an invitation link so that it becomes immediately unusable.
18. As an Owner, I want to initialize the Workspace from a default role template on first entry, so that the RBAC skeleton is ready to use.
19. As an Owner, I want to create and deploy Workflows, so that multi-role activities exist in my Workspace.
20. As an Owner, I want to view the Workspace audit log, so that I can see who did what.

### Admin

23. As an Admin, I want to approve/reject join requests, so that membership flows without the Owner.
24. As an Admin, I want to manage members and roles, so that I can keep the club running.
25. As an Admin, I want to create and deploy Workflows, so that activities can be structured.

### Tutor

26. As a Tutor, I want to build and deploy Workflows, so that I can turn a course idea into an executable flow.
27. As a Tutor, I want to execute the Steps authorized to me (e.g. syllabus design) via my local OpenClacky, so that I can progress an activity.

### Volunteer

28. As a Volunteer, I want to execute the Steps authorized to me (e.g. recruitment material) via my local OpenClacky, so that I can contribute to an activity.
29. As a Volunteer, I want to generate invitation links, but never with Admin-level pre-authorized roles, so that onboarding stays within my power.
30. As a Volunteer, I want to be blocked from deploying Workflows, so that the platform enforces the permission matrix.

### Learner

31. As a Learner, I want to execute the learning Steps authorized to me (e.g. practice Q&A) via my local OpenClacky, so that I participate in the activity.
32. As a Learner, I want to be blocked from deploying Workflows and generating invitations, so that the platform enforces the permission matrix.

### Workflow 构建与 OpenClacky 对接

42. As a teacher using OpenClacky, I want to trigger the workspace-workflow-builder skill, so that I can design a Workflow in natural conversation.
43. As a teacher, I want the builder to clarify audience/goal/scale/duration and output a validated Workflow DSL (JSON), so that the design is complete before deploy.
44. As a teacher, I want to preview the Workflow locally before deploying, so that I can review without touching the platform.
45. As a teacher, I want to deploy the Workflow to my Workspace through cgc-bridge, so that it becomes real Workflow/Step resources (idempotent by name+workspace).
46. As a teacher, I want deploy requests that violate RBAC to be rejected with 403 and honestly reported, so that I know I lack permission instead of the tool silently failing.
47. As a teacher, I want a Workflow detail page rendering the Steps (roles + agent hints), so that collaborators see the flow.
48. As a teacher, I want an "Edit in OpenClacky" entry on the Workflow page, so that I can return to editing in my local client.
49. As any user, I want a guided "install CGC extension + issue token + paste config" page, so that connecting my local OpenClacky is turnkey.
50. As any user, I want to issue an API token per workspace with capability scopes (read / workflow:write / step:write) and custom expiry, so that I grant minimal rights.
51. As any user, I want to revoke a token with one click so that it is invalid globally and immediately.

### Step 执行(本地 OpenClacky,状态回传平台)

52. As a role-authorized user, I want to see the Steps I'm allowed to execute (workflow detail page), so that I know my tasks in the activity.
53. As a role-authorized user, I want Steps to unlock in order (Step N+1 after Step N completes), so that the activity flows sequentially.
54. As a role-authorized user, I want to execute a Step in my local OpenClacky (its agent_hint points to a local agent), so that the AI work happens on my machine.
55. As a role-authorized user, I want to report Step completion back to the platform through cgc-bridge, so that the Workflow advances and the activity is traceable.
56. As a user, I want the platform to reject any Step execution/report that my role isn't authorized for (403), so that local clients cannot bypass the matrix.

### 安全与审计

57. As the platform, I want unauthenticated or invalid/expired/revoked tokens to yield 401, so that only real identities pass.
58. As the platform, I want a valid token of a non-member of the target workspace to yield 403, so that membership gates everything.
59. As the platform, I want role-based denials (e.g. Learner deploying a Workflow) to yield 403, so that the matrix is enforced on every request.
60. As the platform, I want cross-workspace resource access to yield 403, so that tenants never leak.
61. As the platform, I want every API request (success or failure) written to the audit log (actor, client, action, resource, workspace, ip, result, time), so that there is a complete trail.
62. As a user, I want to view my own audit records; as Owner/Admin, the Workspace's records, so that accountability is visible.
63. As the platform, I want user-created Skills to be treated as legitimate clients with zero extra privilege, so that bypass attempts are impossible.

## Implementation Decisions

### 1. 技术栈(版本已锁定)

- 后端 Elixir/Phoenix 1.8 + Ash 3.31(ash_postgres 2.11、ash_graphql 1.10、ash_authentication 4.14 + phoenix 2.4、cors_plug 3.0 已装);新增 ash_state_machine 0.2.13、ash_archival 2.0.3。审计二期用 ash_paper_trail。**不含 ash_ai / ash_oban——平台不执行 LLM**。
- 前端 Next.js 16 App Router + Apollo Client 4(已装),全客户端渲染("use client" + ApolloProvider),不引入 streaming-RSC;新增 Vitest + @testing-library/react。
- 明确不用:ash_rbac(角色编译期写死)、ash_audit_log(包不存在)、GraphQL subscriptions、ash_ai/ash_oban(LLM 执行在本地)、Redux/zustand(只用 Apollo cache)。

### 2. 多租户与资源边界

- 共享表 + attribute 多租户:`workspace_id` 列过滤,不用 schema-per-tenant。
- 全局资源(User、Workspace、Identity、Token)无租户;其余全部租户资源(Role、WorkspaceMembership、MembershipRole、Workflow、Step、StepRole、Invitation、JoinRequest、Profile)。
- 两个 Api 模块:租户 Api(默认要求 tenant)+ 全局 Api;租户资源的创建 action 必须显式 set_tenant(取自 actor 的 membership),防跨租户写入。
- 多租户上下文在认证 plugs 之前设置。
- Workspace 字段:slug(全局唯一,展示用)、name、join_policy(open/request/invite_only)、UUID 主键;加入策略仅 Owner 可改。

### 3. 认证与 Token(严格授权链第 1 环)

- ash_authentication Password 策略 + TokenResource;JWT `session_unique_id: :jti`;`store_all_tokens? true` + `require_token_presence_for_authentication? true`(白名单模式:token 必须在 token_resource 中存在才有效)。
- 自建 ApiToken 实体(机器/扩展凭证,非会话 JWT):绑定 user_id + workspace_id + name + scopes(read/workflow:write/step:write)+ expires_at(默认 30 天)+ revoked_at;**平台只存 token_hash,不落明文**;签发/撤销是普通 Ash action,受 RBAC;撤销 = revoked_at 置位,每请求查表即时全局失效。
- 每请求认证:`load_from_bearer` plug 挂 `/api/v1/*` 与 `/api/graphql` 两个管道。

### 4. 授权(严格授权链第 2–4 环,自研)

- 自研 `Cgc2046.Rbac` 模块:`can?(actor, permission, opts)` 读 actor 的 memberships + 角色(预加载),多角色权限取**并集**;Step 授权为成员角色集与 Step 允许角色集求**交集**。
- 每个租户资源 `policies` 声明:租户内可读(workspace_id == actor 的 workspace)、写操作走 Rbac 判定;统一约定所有写 action 首行 `Rbac.ensure!`(失败返回 Forbidden/403)。
- 权限矩阵:创建/部署 Workflow = Owner/Admin/Tutor;Step 执行/回传 = 按 Step 授权(角色交集);成员管理 = Owner/Admin;角色管理 = Owner;邀请 = Owner/Admin/Volunteer(Volunteer 不可预授权 Admin 级);Workspace 管理/审计 = Owner。无任何 agent:* 权限——Agent 不是平台资源。
- 平台管理员:`User.is_platform_admin`(全局标记,可多人),唯一能创建 Workspace 并指定 Owner。

### 5. API 契约(双轨共享同一批 Ash action)

- **REST `/api/v1/*`**(OpenClacky 主入口):`POST /api/v1/workflows`(部署,幂等:workspace_id+name 存在则更新)、`GET /api/v1/me`(token 身份 + 能力域 + 可执行 Step,渲染"我能做什么")、`GET /api/v1/workspaces/:id/workflows`(列表/详情)、`POST /api/v1/workspaces/:wid/workflows/:id/steps/:step_id/complete`(Step 完成回传,推进状态机)。JSON body;`X-CGC-Client` 审计头。
- **GraphQL `/api/graphql`**(网站用):AshGraphql 自动生成 query/mutation。
- **错误契约**:401 认证失败 / 403 越权 / 409 冲突 / 422 DSL 校验失败,body `{"error": "..."}`。
- 安全边界在两壳之下:认证在 plug、授权在 Ash policies——REST 与 GraphQL 无差别。

### 6. Workflow DSL 契约(平台与扩展的接口)

- 部署 payload(JSON):`{ "name", "description", "dsl_version": 1, "steps": [{ "position", "title", "type", "allowed_roles": ["Tutor"], "agent_hint" }] }`。
- 服务端校验:step 顺序(position 连续、无遗漏)、allowed_roles 引用存在的 Role、类型合法;非法 → 422。
- Workflow 资源存 `dsl_version`,为 DSL 演进留档。
- 不做可视化构建 UI:构建唯一入口是 OpenClacky 的 workspace-workflow-builder 技能。

### 7. Workflow / Step 状态机与顺序解锁

- Workflow:草稿 → 发布 → 归档(ash_state_machine);归档后不可执行。
- Step:待执行 → 进行中 → 完成;Step N+1 在 Step N 完成后才可执行(顺序约束)。
- 执行发生在本地:Step 的 agent_hint 是文本提示,供本地 OpenClacky 解析为对应 Agent;本地完成后经 cgc-bridge 回传 complete,平台只做授权校验(角色交集)与状态推进。

### 8. AI 执行在本地(平台无 LLM)

- **平台不做任何 AI**:不执行 LLM、不托管 Agent、不提供流式对话。Agent 是本地 OpenClacky 的概念(扩展预置的官方 Agent 与用户自建的个人 Agent),平台侧**没有 Agent / AgentRun 资源**。
- 交互闭环:本地 OpenClacky(官方 Agent 或自建 Skill)经 cgc-bridge 调平台 REST API——部署 Workflow、查"我能做什么"、执行 Step 后回传完成。平台按同一授权链判定,客户端来源不影响权限。
- Step 执行状态回传:**客户端自报**(本地完成 → POST complete),平台只验证"执行者角色 ∩ Step 允许角色非空"与顺序约束,不验证"是否真的做了"——MVP 接受,类似打卡;如需强校验二期再加(如回传附执行摘要哈希)。
- 可选二期:平台发布 MCP server 暴露同一批 REST 能力,本地 OpenClacky 经 MCP client 直连(替代/补充 cgc-bridge);不阻塞当前规划。

### 9. 前端(Next.js 16)

- `next.config.ts` rewrites 代理 `/api/graphql`(和 `/api/v1`)到后端,消除 CORS;cors_plug 双保险。
- 认证传输:登录 mutation 返回 JWT → httpOnly cookie → Apollo link 中间件附加 `Authorization: Bearer`。
- 页面清单(第一版):注册/登录、公开发现页、Club 公开主页、工作台选择页、Workspace 设置(成员/角色/审批/邀请/加入策略)、Workflow 详情(Step 流程渲染 + "在 OpenClacky 中执行/编辑"入口)、Step 状态浏览(网站只读,执行在本地)、成员 Profile、平台管理后台、设置→API Token 页、扩展安装引导页。

### 10. OpenClacky 扩展「CGC」(承载全部 AI 能力)

- 容器 id `cgc`,人人安装的统一入口——**平台的所有 AI 都在这里**;技能与 Agent 统一 `workspace-` 前缀。
- 贡献:skills(workspace-workflow-builder 核心 + workspace-agent-builder 个人 Agent 构建器)、agents(workspace-tutor 教研助手、workspace-event-prep 活动筹备——本地官方 Agent,Step 的 agent_hint 指向它们)、panels(workflow-viewer、agent-manager)、api(cgc-bridge handler.rb,唯一出入口)。
- 执行闭环:用户在本地与官方/个人 Agent 对话完成 Step 任务 → cgc-bridge 调 `POST .../steps/:id/complete` 回传状态 → 平台校验授权并推进 Workflow。
- cgc-bridge:转发到平台 REST,附 `Authorization: Bearer` + `X-CGC-Client`;**不开放 public_endpoint**(一切平台操作要身份);平台拒绝(401/403)时如实转告用户,绝不绕过。
- 用户自建 Skill 可直连平台 API,但平台按同一授权链判定——客户端来源不影响权限。

### 11. 审计

- audit_log 表:`actor_id, client, action, resource, workspace_id, ip, result, created_at`;每次 API 请求(成功或失败)落一条;普通用户查自己的,Owner/Admin 查 workspace 的。
- 高频 403 可标记提示(告警为可选增强,不阻塞)。

### 12. 加入流程细节

- Invitation:token(hash)存库、expires_at、inviter、workspace、target_email(空=公开链接)、status(active/used/revoked);撤销置 revoked;过期/used 校验失败。
- 链接格式:slug + UUID 末 4 位;未登录先跳登录;校验后预览 Club 公开页再确认。
- JoinRequest:pending/approved/rejected;审批通过时分配角色(申请人可请求角色,审批方指定最终角色——编码阶段细化)。
- Volunteer 生成的邀请链接**不可预授权 Admin 级角色**(生成时校验,超权 403)。

### 13. 其他

- Profile:头像/简介/标签/portfolio 作品展示;租户内可见。
- 软删除:全资源 ash_archival。
- 邀请 token 走自生成 + hash(与 ApiToken 同思路,不落明文)。

## Testing Decisions

### 测试接缝(已与用户确认)

- **接缝 1(主):HTTP API 集成测试** —— 所有后端 TDD 用例从 HTTP 层打:`/api/v1/*`(REST)+ `/api/graphql`,带真实 Bearer token,共享同一套夹具(seed 用户/token/workspace/membership)。理由:授权链的价值在完整链路(plug 认证 → Ash policies → 多租户),domain 层测不到 401/403 语义。REST 与 GraphQL 算一个接缝(同一批 action/policies/夹具)。
- **接缝 2(唯一第二个):Apollo mock 组件测试** —— Next.js 独立运行时,Apollo mock client 测组件外部行为(渲染/交互/错误态),不与后端联调。
- **不在接缝内**:OpenClacky 扩展本身(`clacky ext verify` + P0 手动冒烟);Ash 内部纯逻辑函数(如 DSL 校验)如需要单测,作为辅助用例,不立为主接缝。

### 好测试的标准

- 只测外部行为:HTTP 状态码、响应体、副作用(落库、审计记录、状态流转),不测实现细节(不 mock 内部函数、不断言内部模块调用)。
- 安全用例必须真实走完整链路:用真实 token、真实角色、真实 workspace。
- 失败路径与成功路径同等重要:401/403/409/422 每个都要有对应用例。
- 多租户用例:两个 tenant 各造数据,断言互不可见。

### 被测模块

- 认证链:无/错/过期/撤销 token → 401;白名单模式生效。
- 成员与角色:非成员 → 403;多角色并集判定;跨租户 → 403。
- RBAC:权限矩阵逐操作(Workflow 部署、Step 执行/回传、邀请链接生成)的允许/拒绝两路径。
- Workflow/Step:部署幂等、DSL 校验 422、状态流转、顺序解锁、complete 回传推进。
- Invitation/JoinRequest:三态加入策略、链接校验/撤销/过期、审批分配角色、Volunteer 预授权限制。
- 审计:成功/失败请求都落表;查询权限隔离。
- 前端:登录/注册、发现页、工作台、设置页、Workflow 详情/Step 状态浏览。
- 扩展(不在主接缝):`clacky ext verify` + P0 手动冒烟 + P3 真机闭环。

### Prior art

- 后端:Phoenix 脚手架自带的 `test/support/conn_case.ex` / `data_case.ex`(已存在),controller 测试为既有范式;Oban.Testing 与 Req.Test 为 Elixir 生态标准做法。
- 前端:无既有测试基建(web/ 无 test 目录)——接缝 2 为新建,使用 Vitest + @testing-library/react 标准配置。

## Out of Scope

- 计费/付费/额度限流。
- 二期:Event/Course 插件、子域名租户解析、refresh token 轮换、审计页(AshPaperTrail)、向量知识库、平台 MCP server(暴露 REST 能力供本地直连)、Playwright 冒烟、IM 渠道集成、OpenClacky 市场正式发布(先 local 自测 + draft)。
- 可视化/表单式 Workflow 构建 UI(明确不做,构建入口在 OpenClacky)。
- 平台侧任何 LLM/Agent 执行(明确不做,全部在本地 OpenClacky)。
- 个人设置页(并入账号体系,二期)。

## Further Notes

- 里程碑顺序(每项 = 垂直切片,TDD):M0 业务地基(接线/User/Workspace/租户资源/Rbac/JoinRequest/Invitation/Profile/ApiToken)→ M1 Workflow(Workflow/Step/StepRole/部署权限/状态机/顺序解锁/complete 回传)→ M2 本地执行(扩展:官方 Agent/个人 Agent/Step 执行与回传,`clacky ext verify`)→ M3 前端页面(浏览/设置/管理/Token 页/引导页)→ M4 端到端联调 + 越权演练 + 发布 draft。OpenClacky 扩展的开发与 M0/M1 并行(后端未就绪时 mock)。
- 严格授权链是验收主线:任何"换客户端、换请求头"的越权尝试都必须被同一判定拒绝;越权演练(M4)是发布前置条件。
- 术语与词汇:沿用 docs/领域模型定稿.md 的词汇表(Role 是可扩展实体、Step 是授权最小单元、agent_hint 是本地 Agent 提示);写代码与票据时使用同一套词汇,避免引入同义词。
- 风险:set_tenant 顺序(认证 plugs 之前);多角色并集与 Step 交集两种判定不要混;Step 完成回传是客户端自报(MVP 接受,见决策 8)。
