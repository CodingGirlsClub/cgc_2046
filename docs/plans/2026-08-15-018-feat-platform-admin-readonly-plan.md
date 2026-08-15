# Plan 018 · Platform Admin 只读放行业务工作台（D5 / #160）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：#147 D5 拍板「复用业务页面，只读放行进入业务工作台」
- 关闭目标：#160（B5 平台管理员治理读被前端封死）
- 关联：#105（切片G 平台管理后台，G-5 Workspace 监督）、#114/#115（pending-owner 治理链）

## 1. 问题与目标

**现状**：后端 policy 已放行 PlatformAdmin 跨租户读（Workspace/Event/Course/Workflow/StepRole/SignalLog/Membership/Invitation/Sponsorship/SpeakerInvitation/AdminActionLog 等全集，见 §2.3）；但前端 `WorkspaceShell` 只认 `meWorkspaces` 列表（`workspace-shell.tsx:94-100, 175-227`），而 `me_workspaces` 过滤 `exists(memberships, user_id==actor)`（`workspace.ex:341-347`）——非成员 PlatformAdmin 不在列表 → 进任何业务工作台都撞「工作区不可访问」卡片。治理审计（看事件/工作流详情）走不通。

**同时存在的反向问题**：后端 PlatformAdmin 业务写 bypass 过宽（Event/Course/Workflow/InviteBatch/SpeakerInvitation/Invitation/Sponsorship/join_policy），D5 只读语义不能只靠前端藏按钮。

**目标**：
1. 非成员 PlatformAdmin 可进入任意业务工作台页面（概览/活动/课程/工作流/成员列表），复用现有页面，只读。
2. 前端写入口对 PlatformAdmin 只读访客隐藏/禁用。
3. 后端把「业务写」的 PlatformAdmin bypass 收窄为拒绝，**保留治理写**（pending-owner 生命周期、reassign_owner、Workspace create、审计）。

**非目标**：
- 不改 `meWorkspaces` 合同（成员发现列表保持纯成员语义，`graphql_rbac_test.exs:249-263` 的 non-member admin 不列出断言保持绿——Scout018 确认改它会误伤「成员可见性」合同）。
- 不新建 /admin 治理读页面（那是 D5 选项 B，已否）。
- 不动 #114/#115 治理流程（ownerless 门控、pending-owner 邀请、reassign）。

## 2. 已验证事实（scout 取证，file:line 以 HEAD 0f2abac 为准）

### 2.1 前端拦截面
- `WorkspaceShell` 无角色判断，仅 `useWorkspaceBySlug` → `fetchMyWorkspaces` 列表匹配 slug（`workspace-shell.tsx:94-100`）；不在列表 → `<h1>工作区不可访问</h1>` 整页卡片，不渲染 children（:175-227）。
- `useWorkspaceBySlug`（`web/lib/use-workspace-by-slug.ts:70-93`）+ `fetchMyWorkspaces`（`web/lib/workspaces.ts:136-153`）。
- 已有直查能力未用：`fetchWorkspaceBySlug`（`web/lib/requests.ts:219-226`）→ `GET_WORKSPACE`（`web/lib/graphql/workspace.ts:268-281`，基础字段）；后端 `get_by_slug`/read policy 对已认证 + open/request 放行、invite_only 有 PlatformAdmin bypass（`workspace.ex:453-462`）。
- `WorkspaceShell` 并行 `fetchCurrentProfile`（:104-119）但只用于菜单，未用于访问判定；`isPlatformAdmin` 识别链已存在：`User.is_platform_admin` public（`user.ex:64-75`）→ me query（`graphql_schema.ex:51-73` → `load_profile:1622-1638`）→ `web/lib/graphql/profile.ts:22-85` → `web/lib/profile.ts:61-67, 129-153` → `AdminGuard`（`admin-guard.tsx:5-33`）。

### 2.2 能力/只读语义基础设施
- `CurrentMembershipInfo` 已有非成员 admin 分支：`abilities_for([], true)`（`calculations/current_membership_info.ex:42-80`）——PlatformAdmin 非成员能力集 = view_workspace/access_invite_only/update_join_policy/create_workspace（`rbac.ex:14-50, 80-110`），管理类（list/manage_members/assign）不下发。
- Rbac 注释：update_join_policy 对 admin 是 #78 历史豁免（`rbac.ex:31-44, 89-97`）。

### 2.3 后端读 bypass 全集（保留不动）
Workspace read `workspace.ex:453-462`；Event `event.ex:511-545`；Course `course.ex:476-510`；WorkflowDefinition `workflow_definition.ex:274-283`；WorkflowRun `workflow_run.ex:428-457`（read :431）；Step `step.ex:157-166`；StepRole `step_role.ex:91-103`；SignalLog `signal_log.ex:129-142`；Membership `workspace_membership.ex:171-179`；Invitation `invitation.ex:566-572`；AdminActionLog `admin_action_log.ex:101-104`；Sponsorship `sponsorship.ex:344-350`；SpeakerInvitation `speaker_invitation.ex:353-357`。join_request **无** read bypass（`join_request.ex:291-305`，成员可见面）。

### 2.4 后端写 bypass 分级（Scout018 三轮取证）
**治理写（保留）**：
- Workspace create：`workspace.ex:442-444`。
- pending-owner Invitation create/revoke：`invitation.ex:531-549` + `validate_inviter_role_preauthorization` PlatformAdmin 跳过（`changes/validate_inviter_role_preauthorization.ex:28-33`）；内部 `create_owner_invitation` 走 `authorize?: false`（`workspace.ex:554-600`）。
- `reassign_owner`：`workspace.ex:473-475`（forbid_unless + PlatformAdmin）。
- Workspace update/join_policy：`workspace.ex:446-450`（#78 历史豁免；**决策：保留后端**，前端复用页面只读，见 U2）。
- AdminActionLog read / User promote/demote：非业务写。

**业务写（收窄为拒绝，删 PlatformAdmin bypass）**：
- Event create/update（launch/close/cancel 随 update action_type）：`event.ex:518-522`；Course 同构 `course.ex:483-487`。
- WorkflowDefinition create/update：`workflow_definition.ex:280-283`。
- WorkflowRun 通用 create/update：`workflow_run.ex:456-458`；`update_facts_for_mcp` :447-452 与 `start_run/resume_signal` :437-440 的 PlatformAdmin bypass 一并删（member/learner 路径保留）。
- Step/StepRole/SignalLog 写：`step.ex:163-166`、`step_role.ex:100-103`、`signal_log.ex:138-142`。
- InviteBatch create/update：`invite_batch.ex:123-126`。
- SpeakerInvitation create：`speaker_invitation.ex:332-336`（accept/decline token 语义不动）。
- 普通 Invitation create/revoke：`invitation.ex:531-549` **需拆分**——见 U1.3 难点。
- Sponsorship 档位（走 Event/Workspace update 路径的）随上面收窄；delivery 已仅 Owner/Admin（`sponsorship_delivery.ex:91-101`）。

**本人路径（显式拒绝 admin 本人业务写）**：
- Enrollment create/cancel 仅 `user_id == actor.id`（`enrollment.ex:257-278`）——PlatformAdmin 可写自己的报名。D5 语义：前端隐藏报名按钮；后端加 `forbid` PlatformAdmin（治理审计者不应参与业务流程）。

### 2.5 前端写门控面（UX 层，需对只读访客隐藏）
- 共享：`canManageEvents` = myRoleNames owner/admin（`web/lib/events.ts:40-43`）——admin 只读访客 `myRoleNames=[]` 天然 false ✓。列表新建入口 `offering-pages.tsx:159-205`、详情 update/launch/close/cancel `:326-442, 500-663` 全包 manage ✓。
- **例外（会暴露）**：报名按钮 `offering-pages.tsx:399-446, 614-652` 不检查 admin——只读访客会看到可点的报名按钮（后端 U1 收窄后会 403，但 UI 应先隐藏）。
- 嵌套面板由 host manage render 门控：SpeakerInvitationPanel `offering-pages.tsx:739-747`、InviteBatchPanel `:708-737` ✓。
- SponsorshipManagement 传 manage ✓；列表 query 无 gate（读面，OK）。
- Settings：members 页 assign/edit gate `currentUserCanAssignRoles` ✓（admin 非成员能力集无 assign）；requests/invitations 页 `canManage=manage_members` 不 fetch 仅提示 ✓；**join-policy 页 save gate = `update_join_policy` ability（`join-policy/page.tsx:39-40, 74-80, 147-211`）——admin 能力集含该 ability，会暴露可写 UI**。
- Settings nav gates：members/permissions=list_members（admin 无 → 隐藏 ✓）；requests/invitations=manage_members ✓；policy 恒显（读面 OK）。
- Workflows 页本身只读无 mutation（`workflows/page.tsx:1-12, 99-136`）✓。

### 2.6 测试合同（改动会红的现有测试）
- `graphql_rbac_test.exs:182-273`：owner/admin all abilities、member view/access、outsider 不在 meWorkspaces、**non-member platform admin 不列出**（:249-263 refute slug in list）——保持绿（不改 meWorkspaces）。
- `membership_test.exs:165-190` meWorkspaces 成员范围。
- `graphql_profile_test.exs:64-103` me.isPlatformAdmin。
- `web/app/w/[slug]/page.test.tsx:133-218`：未知 slug 卡片 / 成员与 admin overview。
- `admin-guard.test.tsx`、`web/lib/profile.test.ts`。
- 写入口现有合同：`offering-pages.test.tsx`、`offering-pages.invite-batch.test.tsx`、settings members/requests/invitations/join-policy tests。

## 3. High-Level Technical Design

### U1 Backend：业务写收窄 + admin 本人业务写显式拒绝
1. §2.4「业务写」清单逐项删 `authorize_if(Cgc2046.Policies.PlatformAdmin)`（policy 行删除，不改 action 结构）。每项配一条真实 HTTP GraphQL 拒绝测试（PlatformAdmin 非成员 → `forbidden`；owner/admin 成员 → 照旧通过，钉住只收窄不误伤）。
2. WorkflowRun `update_facts_for_mcp`/`start_run/resume_signal`：删 PlatformAdmin bypass，member/owner/admin/learner(enrolled) 路径原样。
3. **Invitation 拆分（难点）**：pending-owner 治理依赖 create/revoke bypass。方案：policy 从「action_type 级 bypass」改为「条件 bypass」——`authorize_if(expr(preauthorized_role_names == ["owner"] and inviter 平台管理员))` 不可行（expr 复杂）；用 **check 模块** `Cgc2046.Policies.PlatformAdminOwnerInvite`（`match?/3`：actor 是 PlatformAdmin ∧ invitation.preauthorized_role_names 包含 :owner）挂 create/revoke 的 admin 分支；普通角色邀请（tutor 等）的 PlatformAdmin bypass 删除。ownerless 期间 reassign 前只有 owner 预授权邀请可建/撤（与 #114 语义一致）。
4. Enrollment：create/cancel policy 追加 `forbid_if(Cgc2046.Policies.PlatformAdmin)`（在本人 actor 检查之前）。
5. 治理写不动：Workspace create/update/reassign、pending-owner 链、AdminActionLog、promote/demote。`graphql_rbac_test` 补断言：非成员 admin abilities 仍含 update_join_policy（#78 豁免保留，治理 API 面）。

### U2 Web：isPlatformAdmin 只读放行
1. `useWorkspaceBySlug`：`meWorkspaces` 未命中且 `profile.isPlatformAdmin` 时，fallback `fetchWorkspaceBySlug`（GET_WORKSPACE 基础字段）返回 workspace + 标记 `readOnlyVisitor: true`；普通用户不 fallback（保持不可访问卡片）。hook 内并发判定，不阻塞正常成员路径（fallback 仅 miss 时触发）。
2. `WorkspaceShell`：`readOnlyVisitor` 时正常渲染 children + 顶部细条「平台管理员 · 只读审计视图」（提示身份，非阻断）；菜单照常（切换工作台列表仍是 meWorkspaces，admin 用 /admin 导航）。
3. 写入口隐藏（对 readOnlyVisitor）：
   - 报名按钮（`offering-pages.tsx:399-446, 614-652`）：manage 或报名资格判定加 `!readOnlyVisitor`。
   - join-policy save（`join-policy/page.tsx`）：页面级 `readOnlyVisitor` → 表单只读 + 提示。
   - 其余 manage-gated 面板因 `myRoleNames=[]` 天然隐藏，不逐个改。
4. `GET_WORKSPACE` 查询若缺 shell 所需字段（name/slug/joinPolicy 等），补 selection（读面，后端已放行）。

### U3 测试 + e2e
1. 后端：每个收窄点一条拒绝测试 + owner/admin 回归；Invitation 拆分专项（admin 可建/撤 owner 预授权邀请、admin 建普通角色邀请被拒、成员路径不变）；Enrollment admin 本人拒绝 + 普通用户照旧。
2. 前端单测（Scout018 建议 d 组）：a) useWorkspaceBySlug admin fallback 返回 ws；b) 普通用户 fallback null 保持卡片；c) WorkspaceShell admin fixture children 渲染；d) offering 列表/详情、join-policy 对 readOnlyVisitor 隐藏写 UI。
3. e2e（agent-browser，结构断言）：非成员 PlatformAdmin → /w/[slug] 概览可见 → /events 列表可见、详情可见 → 写按钮不渲染 → GraphQL 直发 createEvent 被拒（403 断言，钉后端防线）；普通用户未知 slug 仍卡片。
4. 既有测试保持绿清单核对：§2.6 全集。

## 4. 风险与预案

| 风险 | 概率 | 预案 |
|---|---|---|
| Invitation 条件 bypass 误伤 #114 治理链 | 中 | 专项测试三态（owner 预授权 ✓ / 普通邀请 ✗ / 成员 Owner·Admin ✓）+ 既有 #114 测试回归 |
| 删 Event update bypass 影响 admin 经 /admin 的治理操作 | 低 | #105 /admin 面不做活动业务写（治理面只有 workspace/owner/promote/audit）；advisor 逐项核对 admin 页 mutation 调用集 |
| readOnlyVisitor 状态泄漏到成员路径 | 低 | fallback 仅在 meWorkspaces miss + isPlatformAdmin 双条件下触发；单测 a/b 钉住 |
| GET_WORKSPACE 字段不足导致 shell 崩 | 低 | U2.4 补 selection + e2e 覆盖 |
| join-policy 后端豁免保留但 UI 只读，语义分裂 | 中 | 接受（#78 治理 API 面）；PR 描述记录，后续若要收紧走专用 governance action |

## 5. 验收标准

1. 非成员 PlatformAdmin 经 /w/[slug] 可见概览/活动列表/详情/工作流页，页头有只读标识；写入口（报名/新建/launch/close/join-policy save）不渲染。
2. GraphQL 直发业务写（createEvent/launchEvent/InviteBatch create/普通 Invitation create/Enrollment create）以 PlatformAdmin 身份 → forbidden；owner/admin 成员照旧全绿。
3. pending-owner 治理链全绿：admin 建/撤 owner 预授权邀请、reassign_owner、#114/#115 既有测试。
4. §2.6 既有测试合同全绿（尤其 non-member admin 不在 meWorkspaces）。
5. 全量自查绿：backend ×2 seeds、web 全套、e2e 三组结构断言。

## 6. 实施顺序（writer 契约）

U1 backend 收窄 + 拆分 + 测试 → U2 web fallback + 只读标识 + 写入口隐藏 → U3 e2e → 自查全套 → 本地 commit（不 push）→ 报告 `/tmp/cgc_2046-writer18-report.md`。

## 7. Assumptions（writer 验证，冲突即停）

1. `useWorkspaceBySlug` 可在不改成员主路径的前提下加 fallback（hook 结构 scout 证实 :70-93 单一返回路径）。
2. `GET_WORKSPACE` 现有 policy 对 open/request 工作台已放行任意已认证用户（`workspace.ex:453-462`）——admin fallback 无需后端改动；invite_only 经 PlatformAdmin bypass 亦放行。
3. 报名按钮渲染条件可加 readOnlyVisitor 参数（`offering-pages.tsx` props 传递链存在；若 props 链不通改用 context，报告注明）。
4. miniprogram 不做 D5（平台管理员用 web 治理）。
