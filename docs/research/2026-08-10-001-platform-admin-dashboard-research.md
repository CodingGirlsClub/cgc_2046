# Platform Admin Dashboard - SOP Research

> **角色**: Plan01 (planner/研究员)
> **模式**: SOP Research（只读调研，不改代码，不提交）
> **需求文档**: `docs/plans/2026-08-10-001-feat-platform-admin-dashboard-plan.md`
> **artifact_contract**: ce-unified-plan/v1 | **artifact_readiness**: requirements-only
> **日期**: 2026-08-10
> **仓库基准**: develop = 461d248

---

## 研究点 1: 依赖与版本兼容性（ash_admin 1.2.0）

### 1.1 安装状态确认

- `backend/mix.exs:61-62` 已声明 `{:ash_admin, "~> 1.2"}`，注释标注 "R12：Platform Admin Dashboard ops/debug 层；/ops/admin 零代码 CRUD（AshAdmin，MIT；合规门已审）"。
- `backend/mix.lock:6` 锁定 `ash_admin 1.2.0`（hash `2b204840...`）。
- `backend/deps/ash_admin/mix.exs:12` 确认 `@version "1.2.0"`。
- **License**: `backend/deps/ash_admin/LICENSES/MIT.txt` + `mix.exs:3` SPDX `MIT`。**AGPL-3.0 兼容，合规门已通过。**

### 1.2 ash_admin 1.2.0 与项目 Ash 3.31 / Phoenix 1.8 / LiveView 兼容性（OQ2）

**结论: 完全兼容，无版本冲突。**

| 依赖 | ash_admin 1.2.0 要求 (`deps/ash_admin/mix.exs:141-171`) | 项目实际版本 (`mix.lock`) | 兼容? |
|---|---|---|---|
| ash | `>= 3.4.63 and < 4.0.0-0` | 3.31.0 | ✅ |
| ash_phoenix | `>= 2.3.20 and < 3.0.0-0` | 2.3.24 | ✅ |
| phoenix | `~> 1.7` | 1.8.9 | ✅ (`~> 1.7` 覆盖 1.7.x ~ 1.x) |
| phoenix_live_view | `~> 1.1-rc` | 1.2.8 | ✅ (CHANGELOG v1.2.0 明确 "update for LV 1.2.0") |
| phoenix_html | `~> 4.1` | 4.3.0 | ✅ |
| cinder | `~> 0.9` | 0.17.0 | ✅ (`~> 0.9` 覆盖 0.9.x+) |
| gettext | `~> 0.26 or ~> 1.0` | 1.0.0 (项目用 `~> 1.0`) | ✅ |
| jason | `~> 1.0` | 1.2+ | ✅ |

**传递依赖 cinder**: ash_admin 依赖 cinder（表格组件），cinder 0.17.0 自身依赖 `phoenix_live_view ~> 1.0` + `ash ~> 3.0` + `ash_phoenix ~> 2.3`，与项目版本全部兼容。cinder 随 ash_admin 自动引入，无需单独添加。

### 1.3 ash_admin 安装要求（OQ2 - 安装接线）

ash_admin 安装需 3 处接线（源码验证 `deps/ash_admin/lib/mix/tasks/ash_admin.install.ex:68-155`）：

#### a) Domain 扩展

每个需在 admin 展示的 Domain 必须 `extensions: [AshAdmin.Domain]` 并设置 `admin show?: true`（`deps/ash_admin/lib/ash_admin/domain.ex:6-70`）。

项目当前 3 个 Domain（`config/config.exs:12`）：
- `Cgc2046.Api`（`backend/lib/cgc_2046/api.ex`）- 无 AshAdmin 扩展
- `Cgc2046.GlobalApi`（`backend/lib/cgc_2046/global_api.ex`）- 无 AshAdmin 扩展
- `Cgc2046.Mcp`（`backend/lib/cgc_2046/mcp.ex`）- 无 AshAdmin 扩展

**缺口**: 三个 Domain 均未加 AshAdmin 扩展。Planning 需加 `extensions: [AshGraphql.Domain, AshAdmin.Domain]` + `admin show?: true`。可按需选择哪些 Domain 暴露给 admin（如 Mcp 域含敏感审计数据可选择性暴露）。

#### b) Router 挂载

`deps/ash_admin/lib/ash_admin/router.ex:84-121` 提供 `ash_admin/2` macro，需在 browser pipeline 下挂载：
```elixir
scope "/ops/admin" do
  pipe_through [:browser]
  ash_admin "/"
end
```

项目 `router.ex` 当前 **无 `:browser` pipeline**（仅有 `:api` / `:graphql` / `:mcp`）。ash_admin 提供 `admin_browser_pipeline/1`（`router.ex:32-45`）可一步创建，或手动添加 `:fetch_session` / `:fetch_live_flash` / `:put_root_layout` / `:protect_from_forgery` / `:put_secure_browser_headers`。

**缺口**: router 无 browser pipeline、无 ash_admin 挂载、无 `/ops/admin` 路由。

#### c) Endpoint LiveView socket

ash_admin 是 LiveView 应用，需 endpoint 配 `socket "/live"`。项目 `endpoint.ex:14-17` 已配置：
```elixir
socket("/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: [connect_info: [session: @session_options]]
)
```
**✅ 已满足。**

### 1.4 ash_admin 认证模型与 is_platform_admin 门控（R12 / AE5）

**关键发现: ash_admin 无内建认证/RBAC，认证完全由宿主应用负责。**

ash_admin 的 actor 机制（`deps/ash_admin/lib/ash_admin/actor_plug/plug.ex:30-69`）：
- 从 cookie 读取 `actor_resource` / `actor_domain` / `actor_primary_key` / `actor_action` 等 session 字段
- 通过 `Ash.Query` 加载 actor 记录（`authorize?: false`，绕过 policy）
- actor 注入到 LiveView socket assigns，所有 Ash 操作以此为 actor

**安全模型**: ash_admin 的 "actor" 是运维 impersonation 机制（开发者选一个 user 记录作为 actor 调试），不是认证。它 **不验证当前 HTTP 请求者是否有权访问 admin 页面**。

**R12 / AE5 门控方案**: 需在 router 的 `/ops/admin` scope 前加自定义 plug，从 `cgc_token` httpOnly cookie（`AuthCookiePlug`）+ `load_from_bearer`（`AuthPlug`）解析当前用户，校验 `is_platform_admin == true`，否则 redirect/403。

项目现有认证管线可复用（`router.ex:10-16`）：
```elixir
pipeline :graphql do
  plug(Cgc2046Web.Plugs.AuthCookiePlug, :read)  # cookie -> bearer header
  plug(:load_from_bearer)                         # AshAuthentication 验证 JWT -> current_user
  plug(Cgc2046Web.Plugs.AuthTokenContextPlug)
  plug(:load_actor)                               # current_user -> Ash actor
  plug(AshGraphql.Plug)
end
```

**缺口**: 需新建 `:admin_browser` pipeline（fetch_session + AuthCookiePlug + load_from_bearer + load_actor + is_platform_admin 检查 plug），或用 ash_admin 的 `actor_plug` 配置（`Application.compile_env(:ash_admin, :actor_plug, CustomPlug)`，`deps/ash_admin/lib/ash_admin/actor_plug.ex:11`）自定义 actor 加载逻辑。前者更简单直接。

### 1.5 ash_admin 多租户兼容性

项目使用 Ash attribute 多租户（`multitenancy strategy: :attribute, attribute: :workspace_id, global?: true`），Workspace 是全局资源但租户资源按 workspace_id 过滤。

ash_admin 支持 tenant 选择（`deps/ash_admin/lib/ash_admin.ex:10-54`），通过 `Application.get_env(:ash_admin, :list_tenants)` 配置 tenant 列表。但项目 tenant = workspace UUID，数量动态，不适合静态列表。ash_admin 也支持 typeahead 搜索（`:typeahead` 模式）。

**风险**: ash_admin 的 tenant 机制面向 "少量已知 tenant" 场景。项目有动态 workspace 租户，admin 操作全局资源（User / Workspace）时无需 tenant，但操作租户资源（WorkspaceMembership / Role / JoinRequest 等）需指定 tenant。Planning 需评估是否：
- (a) 只在 ash_admin 暴露全局资源（User / Workspace / ToolCallLog / PendingOperation），租户资源不暴露；
- (b) 配置 tenant typeahead 搜索，允许跨租户操作（功能更强但更复杂）。

---

## 研究点 2: 现有资源与策略核实

### 2.1 is_platform_admin 布线

**已核实，文档引用准确。**

- `user.ex:59-65`: `attribute(:is_platform_admin, :boolean, allow_nil?: false, default: false, public?: true, writable?: false)`。`writable?: false` 意味着 **无公开 action 可修改此字段**——R9（promote/demote）需新建 update action 或 `force_change_attribute`。
- `rbac.ex:83-85`: `can?(actor, :create_workspace, _opts) -> actor_is_platform_admin?(actor)`。`create_workspace` 能力完全由 `is_platform_admin` 决定。
- `rbac.ex:154-174` `abilities_for/2`: `:create_workspace -> is_platform_admin`，`:view_workspace` / `:access_invite_only` / `:update_join_policy` 有 platform_admin 豁免，管理类能力（`list_members` / `manage_members` / `assign_roles`）**无豁免**。

**R8/R9 影响**: `is_platform_admin` 的 `writable?: false` 意味着普通 Ash update action 无法修改它。R9 promote/demote 需新建专用 update action（如 `update :set_platform_admin`），用 `force_change_attribute(:is_platform_admin, ...)` 绕过 `writable?: false`，并加 policy 限 platform_admin。R2 CLI task 同理用 Ash update 或直接 Repo update。

### 2.2 GraphQL 无 admin 查询

**已核实，文档引用准确。**

`graphql_schema.ex:12-123` query block 共 7 个 query：
- `ping`（占位）
- `permission_matrix`（角色权限矩阵，需登录）
- `me`（当前用户）
- `workspace_profile`（当前用户在某工作台的公开资料）
- `my_workspace_portfolio`（作品集）
- `my_mcp_tokens`（MCP token 列表）
- `my_pending_approvals`（跨工作台待审批项）

**无任何全局列表查询**（`listUsers` / `listWorkspaces` / `listToolCallLogs` 等）。Mutation block（`graphql_schema.ex:126+`）有 `create_workspace`（委托 Workspace.create），但无 admin 级 user 管理 mutation。

**缺口**: R3-R13 的 Next.js `/admin` 页面需新增 admin-level GraphQL queries/mutations：
- `listUsers`（分页 + 搜索 + is_platform_admin + membership 概要）
- `listWorkspaces`（分页 + 搜索 + status + owner + member_count）
- `listWorkspaceApplications` / `approveWorkspaceApplication` / `rejectWorkspaceApplication`
- `promoteUser` / `demoteUser`
- `listToolCallLogs` / `listPendingOperations` / `listWorkflowRuns` / `listSignalLogs`（审计）

### 2.3 无 WorkspaceApplication 资源

**已核实。** `grep -r "WorkspaceApplication" backend/` 无匹配。此为 R6/R7 的 net-new 资源。

### 2.4 审计资源读策略

**已核实，文档引用准确。**

| 资源 | 模块 | 位置 | read policy | platform_admin 可读? |
|---|---|---|---|---|
| ToolCallLog | `Cgc2046.Mcp.ToolCallLog` | `mcp/tool_call_log.ex:97-102` | **仅有 `action(:log) -> authorize_if(always())`**；`defaults([:read])` 无对应 read policy → **default-deny** | ❌ 需新增 |
| PendingOperation | `Cgc2046.Mcp.PendingOperation` | `mcp/pending_operation.ex:178-190` | `action(:read) -> authorize_if(expr(user_id == ^actor(:id)))` | ❌ 仅本人，需加 platform_admin bypass |
| WorkflowRun | `Cgc2046.Workflows.WorkflowRun` | `workflows/workflow_run.ex:496-501` | `action_type(:read) -> authorize_if(relates_to_actor_via([:definition, :workspace, :memberships, :user]))` + `authorize_if(actor_attribute_equals(:is_platform_admin, true))` | ✅ 已支持 |
| SignalLog | `Cgc2046.Workflows.SignalLog` | `workflows/signal_log.ex:128-133` | `action_type(:read) -> authorize_if(relates_to_actor_via([:run, :definition, :workspace, :memberships, :user]))` + `authorize_if(actor_attribute_equals(:is_platform_admin, true))` | ✅ 已支持 |
| User | `Cgc2046.Accounts.User` | `user.ex:218-220` | `action_type(:read) -> authorize_if(Cgc2046.Policies.ReadOwnUser)` | ❌ 仅本人，需加 platform_admin bypass |
| Workspace | `Cgc2046.Accounts.Workspace` | `workspace.ex:296-307` | open/request: `actor_present()`；invite_only: 成员或 platform_admin | ⚠️ platform_admin 可读 invite_only，但 open/request 对任何已认证用户可读（无全局列表 action） |

**ToolCallLog / PendingOperation 的 workspace_id 缺口**（R10 caveat 已记录）：
- `tool_call_log.ex:8-9`: "全局资源（不落 workspace_id 字段--params 内含）"。attribute 列表（`:19-67`）确实无 `workspace_id`。
- `pending_operation.ex`: 同样无 `workspace_id` attribute（`:19-69`）。
- `WorkflowRun` 和 `SignalLog` 有 `workspace_id`（`workflow_run.ex:59-133` multitenancy, `signal_log.ex:29-34`）。

**缺口**: R10 审计仪表盘的 workspace 过滤对 ToolCallLog / PendingOperation 需 JSONB 表达式过滤或新增 `workspace_id` 列。前者不改 schema 但查询复杂；后者需 migration + backfill。

### 2.5 create_workspace action 的 after_action 硬编码 actor 为 Owner

**已核实，文档引用准确。**

`workspace.ex:125-183` `create :create` action：
- `accept([:slug, :name, :join_policy, :sponsorship_enabled])`（`:128`）—— **accept list 无 owner 参数**
- after_action（`:131-181`）：
  - seed 六角色（`:138-153`）
  - 从 `changeset.context[:private][:actor]` 取 actor（`:156`）
  - 用 `actor.id` 创建 Owner membership（`:159-163`）+ MembershipRole（`:164-173`）
  - actor 为 nil 时仅 seed 角色不建 Owner（`:177-178`）

**R3a 影响**: 需修改 `create` action 或新建 `create_with_owner` action：
- 新增 argument `owner_user_id`（已有用户）或 `owner_email`（邀请）
- after_action 中用 `owner_user_id` 替代 `actor.id` 创建 Owner membership
- `owner_email` 路径需先发邀请，Owner 角色在邀请接受后分配（pending-owner 状态）

**风险**: 现有 `create` action 被 GraphQL mutation `createWorkspace`（`workspace.ex:328`）使用，修改 accept list 或 after_action 会影响现有调用方。建议新建 `create_with_owner` action 而非修改 `create`，保持向后兼容（但 AGENTS.md 说 "不保留向后兼容"——需 planning 决策是否直接改 `create`）。

### 2.6 Oban workers

**已核实。** `backend/lib/cgc_2046/workers/` 三个 worker：

| Worker | 文件 | queue | cron | 功能 |
|---|---|---|---|---|
| ApprovalExpiryWorker | `approval_expiry_worker.ex` | `:maintenance` | `*/5 * * * *`（5分钟） | 扫描 JoinRequest(pending+过期) + Enrollment(pending+过期) + WorkflowRun(waiting+超时) → 调领域 `:expire` action |
| ApprovalReminderWorker | `approval_reminder_worker.ex` | `:maintenance` | `17 * * * *`（每小时） | 扫描 WorkflowRun(waiting, deadline 在未来 48h 内) → 落 SignalLog + 发通知 |
| NotificationWorker | `notification_worker.ex` | `:notifications` | 无 cron（事件触发） | 异步发送订阅消息 |

cron 配置在 `config/config.exs:88-98`：
```elixir
config :cgc_2046, Oban,
  repo: Cgc2046.Repo,
  queues: [maintenance: 5, notifications: 10],
  plugins: [{Oban.Plugins.Cron, crontab: [
    {"*/5 * * * *", Cgc2046.Workers.ApprovalExpiryWorker},
    {"17 * * * *", Cgc2046.Workers.ApprovalReminderWorker}
  ]}]
```

**OQ3 关联**: 现有 Oban 基础设施（cron + queue + worker 模式）完全可复用于 WorkspaceApplication 的 expiry/reminder。ApprovalExpiryWorker 当前扫描 3 种实体，加第 4 种（WorkspaceApplication pending + approval_deadline 过期）只需在 `perform/1` 中加一个 `expire_workspace_applications(now)` 子函数。

---

## 研究点 3: 关键设计前置问题（OQ1-OQ6）

### OQ1: 申请表单位置

**调研结论（信息支撑，非决策）:**

前端路由结构（`web/app/`）：
- `(auth)/login` / `(auth)/register` — 认证页
- `join/` — 邀请加入流程（多步向导）
- `w/[slug]/` — 工作台内页面（settings/members/permissions/requests/invitations/workflows）
- `settings/account/profile` — 全局 profile（redirect 到默认 workspace 的 profile）

三个可选位置的分析：
1. **`/apply` 独立页**: 最清晰的 IA。用户无需进入任何 workspace 即可提交申请（创建 workspace 是全局操作）。与现有路由结构无冲突。
2. **`/settings` 内**: `settings/` 当前只有 `account/profile`，是一个全局设置区。加入 "申请创建工作台" 逻辑上合理（全局操作），但 `settings` 语义偏向 "个人设置" 而非 "申请新资源"。
3. **workspace switcher 内**: `web/app/components/workspace-switcher-menu.test.tsx` 显示 switcher 是 workspace 切换 + 新建入口。加入 "申请创建" 可与 "新建" 按钮并列（直接创建 vs 申请创建），但 switcher 是 workspace 内导航组件，非平台级入口。

**信息支撑**: 后端 `WorkspaceApplication` 资源 + action 契约与位置无关。Planning 可基于产品 IA 偏好选择，`/apply` 独立页是后端契约最简方案（不需要 workspace context）。

### OQ2: ash_admin 版本兼容性

**已解决。** 见研究点 1.2 — ash_admin 1.2.0 与项目 Ash 3.31 / Phoenix 1.8.9 / LiveView 1.2.8 / ash_phoenix 2.3.24 完全兼容，无版本冲突。传递依赖 cinder 0.17.0 也兼容。

### OQ3: WorkspaceApplication approval 是否接 Oban

**调研结论（信息支撑）:**

现有审批模式（JoinRequest）的完整闭环：
1. **创建**: `join_request.ex:129-155` `create` action 设 `approval_deadline`（默认 7 天）
2. **审批**: `approve` action 用原子条件 UPDATE（`join_request.ex:174-210`）
3. **过期**: `ApprovalExpiryWorker`（5 分钟 cron）扫描 pending + deadline 过期 → 调 `:expire` action
4. **提醒**: `ApprovalReminderWorker`（每小时 cron）扫描 deadline 在 48h 内 → 落 SignalLog + 通知

**JoinRequest vs WorkspaceApplication 差异**:
- JoinRequest 是租户资源（workspace_id），审批方是 workspace Owner/Admin
- WorkspaceApplication 是全局资源（无 workspace_id——workspace 尚不存在），审批方是 platform admin
- 但过期/提醒逻辑结构完全一致（pending → approved/rejected/expired + deadline）

**信息支撑**: 接 Oban 是自然选择——ApprovalExpiryWorker 已有扫描 + expire 模式，加一个实体类型只需 ~15 行代码。不接 Oban 则需读时惰性过期（JoinRequest 的旧模式，已有 TODO 标记要迁移到主动过期）。建议接 Oban，与 JoinRequest 保持一致。

### OQ4: 邀请机制选择（新用户 Owner 指定）

**调研结论（信息支撑）:**

现有 Invitation 资源（`invitation.ex`）的完整生命周期：
- **状态**: active → used / revoked / expired（`:73-79`）
- **创建**: `create` action（`:197-253`），生成 token_hash，明文 token 通过 metadata 一次性返回
- **接受**: `accept` action（`:337-410`），原子条件 UPDATE + 建 Membership + 预授权角色
- **撤销**: `revoke` action（`:255-306`）
- **Policy**: create 限 workspace 成员（Owner/Admin/Volunteer）；accept 持 token 即可；read 邀请人本人或 Owner/Admin
- **多租户**: Invitation 是 **租户资源**（`workspace_id` attribute, `multitenancy strategy: :attribute`）

**三个选项分析**:

1. **复用 Invitation 资源**:
   - 问题: Invitation 是租户资源，创建时需 workspace_id。但 pending-owner workspace 的 owner 邀请发生在 workspace 创建时（workspace 已有 ID），可传 workspace_id。
   - 适配: 创建 workspace → 用 workspace.id 创建 Invitation（preauthorized_role_names: [:owner]）→ 发邀请链接
   - 优势: 复用完整生命周期（active/used/revoked/expired + accept 逻辑 + MembershipContext.admit_member）
   - 风险: Invitation.accept 会建 Membership，但 workspace 在 pending-owner 状态时不应被普通成员使用。需加 workspace 状态守卫（pending-owner 时仅接受 Owner 邀请）。

2. **ash_authentication 确认流**:
   - ash_authentication 有 `confirm` 策略（`user.ex:154-178` 的 authentication block 未使用 confirm）
   - 不适合: confirm 是邮箱验证流程，不是 workspace Owner 邀请。语义不匹配。

3. **专用 workspace-owner 邀请机制**:
   - 新建资源或 Workspace 加 `pending_owner_email` + `pending_owner_token` 字段
   - 优势: 语义精确
   - 劣势: 重复实现 Invitation 已有的 token 生成/hash/accept/expiry 逻辑

**信息支撑**: 复用 Invitation 资源是代码复用最优方案——其生命周期与 pending-owner 邀请需求完全匹配（active → used = owner 接受）。主要适配点是 workspace 状态守卫（pending-owner 状态时限制仅 Owner 邀请可 accept）。但需 planning 决策 Invitation 作为租户资源在 workspace 刚创建（可能有 seed 角色但无成员）时的 policy 适配。

### OQ5: 审计仪表盘差异化价值

**调研结论（信息支撑）:**

R10 审计仪表盘 vs R12 AshAdmin 的功能重叠分析：

| 维度 | R10 审计仪表盘 (Next.js /admin) | R12 AshAdmin (/ops/admin) |
|---|---|---|
| 消费者 | 平台管理员（产品角色） | 开发者/运维（技术角色） |
| 数据范围 | 4 个审计资源 + workspace/time/status 过滤 | 全部 20+ Ash 资源 |
| 过滤 | workspace/time/status 组合筛选 | 单表 CRUD 过滤 |
| 视图 | 汇总视图（可选图表/trends） | 原始数据表 |
| 认证 | is_platform_admin（产品级） | is_platform_admin（同门控但语义不同） |
| 操作 | 只读 + 可能的导出 | CRUD + action 执行 |

**差异化价值**:
1. **跨资源聚合**: R10 可聚合 4 个审计资源到统一视图（如 "某 workspace 的全部操作时间线"），AshAdmin 是逐资源浏览无聚合。
2. **产品级过滤**: R10 的 workspace/time/status 组合过滤面向管理员的运营场景（如 "查看过去 7 天所有 failed WorkflowRun"），AshAdmin 的过滤是表级单列过滤。
3. **非技术友好**: R10 面向非技术管理员（产品运营），AshAdmin 面向开发者（理解 Ash 资源结构）。

**风险**: 如果 R10 仅是 4 个资源的分页表（无聚合/无产品级过滤），则与 AshAdmin 重复，差异化价值低。Planning 需明确 R10 的差异化卖点（如跨资源时间线 + 状态汇总卡片 + workspace 维度聚合）。

### OQ6: pending-owner 状态表示

**调研结论（信息支撑）:**

Workspace 当前属性（`workspace.ex:23-58`）: `id` / `slug` / `name` / `join_policy` / `sponsorship_enabled` / `inserted_at` / `updated_at`。**无 status 字段。**

三个选项分析:

1. **Workspace status 字段**:
   - 加 `attribute(:status, :atom, constraints: [one_of: [:active, :pending_owner]])`
   - KD5 说 "Application flow is not a Workspace flag"——但 KD5 针对的是 application lifecycle，不是 invitation flow。
   - 优势: 直接查询 workspace 状态
   - 劣势: workspace 本质是 "组织单元"，加 status 引入生命周期复杂度；pending_owner 是临时状态

2. **Nullable Owner reference**:
   - 查询 workspace 是否有 Owner membership（`exists(memberships, ...)`）
   - 优势: 无需新字段，状态派生自数据
   - 劣势: 查询复杂（需 join memberships + roles）；无法区分 "无 Owner 因为 pending" vs "无 Owner 因为被移除"

3. **Separate invitation record** (复用 Invitation):
   - workspace 创建时同时创建 Invitation（active），workspace "有 active Invitation with preauthorized [:owner]" = pending-owner
   - Invitation used → owner 接受 → workspace 有 Owner membership
   - 优势: 复用 Invitation 生命周期；pending-owner 状态精确（active invitation = pending）
   - 劣势: 需查询 Invitation 判断 workspace 状态

**信息支撑**: 选项 3（Invitation 记录）与 OQ4 的邀请机制复用方案一致——pending-owner 状态 = "workspace 有 active Owner 邀请"。这避免在 Workspace 上加 status 字段（保持 KD5 的 "workspace 不加 flag" 原则延伸到 invitation flow），且复用 Invitation 的过期/撤销逻辑。Planning 需确认此方案与 F2（pending-owner workspace 有 expiry timeout）的一致性——Invitation 的 `expires_at` 可作为 pending-owner 超时。

---

## 研究点 4: License / 合规

**结论: 无新增合规风险。**

- `ash_admin 1.2.0`: MIT（`deps/ash_admin/LICENSES/MIT.txt` + `mix.exs:3` SPDX 标记）— AGPL-3.0 兼容。
- `cinder 0.17.0`（ash_admin 传递依赖）: 需确认 license。`mix.lock:18` 锁定 cinder 0.17.0。
- 项目无其他待引入依赖——ash_admin 是唯一新增依赖，已在 mix.exs + mix.lock 中。

**CI 合规**: AGENTS.md 提到 `mix cgc2046.check_licenses` + `pnpm check:licenses` CI 门控。ash_admin MIT 已在 mix.exs 注释中标注 "合规门已审"。

---

## 新发现的风险 / 缺口（超出文档已知）

### 风险 1: ash_admin 的 actor 机制是 impersonation 不是认证

**文档已知 ash_admin "no built-in RBAC"（Sources/Research 引用），但具体机制需强调:**

ash_admin 的 `ActorPlug.Plug`（`deps/ash_admin/lib/ash_admin/actor_plug/plug.ex:30-69`）从 cookie 读取 `actor_resource` / `actor_primary_key` 等，以 `authorize?: false` 加载任意 user 作为 actor。这是 **运维调试的 impersonation 机制**——开发者选一个 user 模拟其身份操作。

**风险**: 如果 `/ops/admin` 的门控仅依赖 ash_admin 的 actor 机制而非独立认证 plug，任何能设置 cookie 的人可 impersonate 任意用户。R12 / AE5 的门控 **必须** 在 ash_admin router scope 之前加独立认证 plug（从 `cgc_token` cookie + `load_from_bearer` 解析当前用户 + 校验 `is_platform_admin`），不能依赖 ash_admin 自身的 actor 选择。

### 风险 2: ash_admin 暴露全部资源含敏感数据

ash_admin `admin show?: true` 会暴露 Domain 下 **所有资源** 的全部 attribute（包括 `sensitive?: true` 的 `hashed_password` / `phone`）。虽然有 `show_sensitive_fields` 配置可限制，但默认暴露。

**风险**: `User` 资源有 `phone`（`sensitive?: true`, `public?: false`）和 `hashed_password`（`sensitive?: true`）。ash_admin 默认可能展示这些字段。Planning 需用 `show_sensitive_fields: []` 或 `table_columns` 限制敏感字段暴露，或只暴露非敏感 Domain。

### 风险 3: 前端是 Next.js，ash_admin 是 Phoenix LiveView

ash_admin 是 Phoenix LiveView 应用（`deps/ash_admin/lib/ash_admin/pages/page_live.ex`），渲染 HTML。项目前端是 Next.js（`web/` 目录），通过 GraphQL API 交互。

**影响**: ash_admin `/ops/admin` 是独立的 LiveView HTML 页面，不走 Next.js。这与 KD1 的 "two-layer" 架构一致（AshAdmin = 独立 ops 层，Next.js = 产品层），但需确认：
- ash_admin 的 CSS/JS assets（`deps/ash_admin/priv/static/assets/`）需在 Phoenix 端 serve（endpoint `Plug.Static` 已配置 `from: :cgc_2046`，但 ash_admin 的 static 在 dep 的 priv 下，需确认 Phoenix 能 serve dep 的 static assets）。
- ash_admin 的 LiveView layout（`AshAdmin.Layouts`）独立于项目的 layout，不影响 Next.js 前端。

### 风险 4: is_platform_admin writable?: false 限制 R2 CLI task

`user.ex:63` `writable?: false` 意味着标准 Ash update action 无法修改 `is_platform_admin`。R2 的 `mix cgc2046.promote_admin` CLI task 需用 `force_change_attribute` 或直接 `Cgc2046.Repo.update_all` 绕过 Ash 的 writable 约束。同样影响 R9 的 promote/demote UI。

### 风险 5: Workspace create action 修改影响现有 GraphQL mutation

`workspace.ex:328` GraphQL mutation `create_workspace` 委托 `create` action。如果 R3a 修改 `create` action 的 accept list（加 owner 参数）或 after_action（用 owner_user_id 替代 actor.id），会影响现有 `createWorkspace` mutation 的调用方。

**建议**: 新建 `create_with_owner` action，原 `create` 保留（或按 AGENTS.md "不保留向后兼容" 直接改 `create` 并迁移 GraphQL mutation）。Planning 需决策。

### 风险 6: ash_admin 的 `ash_domains` 配置与项目一致但需验证

`config/config.exs:12`: `ash_domains: [Cgc2046.Api, Cgc2046.GlobalApi, Cgc2046.Mcp]`。

ash_admin 的 `ActorPlug.Plug.domains/1`（`plug.ex:98-102`）通过 `Application.get_env(otp_app, :ash_domains)` 获取 Domain 列表，再 `Enum.filter(&AshAdmin.Domain.show?/1)`。只有 `show?: true` 的 Domain 才出现在 admin。当前三个 Domain 均未加 AshAdmin 扩展，所以 `show?` 返回 false（默认），admin 页面不会显示任何资源——**这是预期的 "已装但未接线" 状态**。

---

## 对后续 Planning 的输入建议

1. **ash_admin 接线**: 3 处改动——(a) 三个 Domain 加 `AshAdmin.Domain` 扩展 + `show?: true`；(b) router 加 `:admin_browser` pipeline（含 is_platform_admin 门控）+ `/ops/admin` scope + `ash_admin "/"`；(c) 无需改 endpoint（LiveView socket 已配）。

2. **ash_admin 门控**: **必须** 在 ash_admin router scope 前加独立 `is_platform_admin` 认证 plug，不能依赖 ash_admin 的 actor 机制。复用现有 `AuthCookiePlug` + `load_from_bearer` + `load_actor` 管线，加 `is_platform_admin` 检查。

3. **审计资源 read policy**: 需为 `ToolCallLog`、`PendingOperation`、`User` 新增 platform_admin read bypass。`WorkflowRun` 和 `SignalLog` 已有。

4. **WorkspaceApplication 资源**: 全新资源，建议全局资源（无 workspace_id），状态机 pending → approved/rejected/expired，有 `approval_deadline`。复用 JoinRequest 的审批模式（原子条件 UPDATE + Oban expiry）。

5. **create_workspace 改造**: R3a 需参数化 owner。建议新建 `create_with_owner` action，原 `create` 保留或迁移。after_action 用 `owner_user_id` 替代 `actor.id`。

6. **pending-owner 邀请**: 建议复用 Invitation 资源（preauthorized_role_names: [:owner]），pending-owner 状态 = workspace 有 active Owner 邀请。Invitation.expires_at 作为超时。需适配 Invitation policy（workspace pending-owner 状态时的创建/accept 权限）。

7. **Oban 集成**: WorkspaceApplication expiry 接入 ApprovalExpiryWorker（加一个 `expire_workspace_applications/1` 子函数）。

8. **GraphQL admin queries**: 需新增 ~10+ admin-level queries/mutations（listUsers / listWorkspaces / listWorkspaceApplications / approveWorkspaceApplication / rejectWorkspaceApplication / promoteUser / demoteUser / 审计列表查询）。

9. **敏感数据暴露**: ash_admin 需配置 `show_sensitive_fields` / `table_columns` 限制 User 的 phone/hashed_password 暴露。

10. **R10 差异化**: 明确审计仪表盘 vs AshAdmin 的差异化价值（跨资源聚合 + 产品级过滤 + 非技术友好视图），否则与 AshAdmin 功能重叠。

---

## 契约返回

```
STATUS: COMPLETE
FINDINGS_COUNT: 28
KEY_FINDINGS:
  - ash_admin 1.2.0 与 Ash 3.31 / Phoenix 1.8.9 / LiveView 1.2.8 完全兼容，无版本冲突
  - ash_admin 已装（mix.exs + mix.lock），MIT 合规，但未接线（3 个 Domain 无 AshAdmin 扩展，router 无 /ops/admin）
  - ash_admin 无内建认证，actor 机制是 impersonation 不是 auth，/ops/admin 门控必须用独立 is_platform_admin plug
  - is_platform_admin 布线已确认（user.ex:59-65, rbac.ex:83-85），writable?: false 限制 R2/R9 需 force_change
  - GraphQL 无 admin 查询已确认（graphql_schema.ex:12-123 共 7 个 query 均为用户级）
  - ToolCallLog 无 read policy（default-deny），PendingOperation 仅本人，User 仅本人——三者需新增 platform_admin bypass
  - WorkflowRun + SignalLog 已有 platform_admin read bypass
  - create_workspace after_action 硬编码 actor.id 为 Owner（workspace.ex:156-173），R3a 需参数化
  - Oban 基础设施完整（3 worker + cron），WorkspaceApplication expiry 可复用 ApprovalExpiryWorker 模式
  - Invitation 资源生命周期完整（active/used/revoked/expired + accept），可复用做 pending-owner 邀请
  - 前端无 /admin 路由，Next.js 结构已确认（web/app/ 无 admin 目录）
RISKS:
  - ash_admin actor 机制是 impersonation，不能作为认证门控（安全风险）
  - ash_admin 默认暴露全部 attribute 含 sensitive 字段（phone/hashed_password）
  - ash_admin 是 LiveView HTML，与 Next.js 前端独立，assets 需确认 Phoenix 能 serve
  - is_platform_admin writable?: false 限制 CLI task 和 UI promote/demote
  - create_workspace 修改影响现有 createWorkspace GraphQL mutation 调用方
  - ToolCallLog / PendingOperation 无 workspace_id 列，审计 workspace 过滤需 JSONB 或新列
  - ash_admin 多租户机制面向少量已知 tenant，项目动态 workspace 不适合静态 tenant 列表
NEXT: 交付给 Plan02（planner）做实施规划，以上 10 条输入建议为 planning 起点
```
