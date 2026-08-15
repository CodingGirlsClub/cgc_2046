# Plan 017 · member 语义深重构（B2/B6 根治，#71 地基）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：#147 D3 深化拍板（product owner 澄清 + #147 comment 记录）
- 关闭目标：#151（B2 入座角色口径不一）、#161（B6 权限映射页四行同权）
- 关联：#71（自定义角色，以本重构为地基）

## 1. 问题与目标

**领域事实（用户澄清）**：Workspace 内所有角色本质上都是 Member——Owner/Admin/Tutor/Volunteer/Learner 都是「工作台成员」，差异只是挂在 membership 上的标签。现状数据模型已经是这个形状（`WorkspaceMembership` 表达成员身份，`MembershipRole` 多对多挂角色标签，`membership_context.ex:344-348` 注释「一个成员可持多个角色（多角色并集）」）。

**病根**：`Role.role_names/0`（`role.ex:27`）把 `:member` 列为与 `:tutor/:volunteer/:learner` 平级的第六个角色。由此产生：
- B2：`/join open` 入座挂 `[:learner]`（`workspace.ex:397-402`）vs 注册自动入 2046 挂 `[:member]`（`membership_context.ex:317`）——两条路径给「无差异标签的普通成员」挂了不同词汇，能力完全同权（`rbac.ex:104-109`）。
- B6：权限映射页把四个同权角色展示为四行不同权限（`web/lib/permissions.ts:20-22`，`web/app/w/[slug]/settings/permissions/page.test.tsx:62-64`），误导用户。

**目标模型（一次到位）**：
1. `member` 退出 Role 枚举。成员资格天然 = 存在 `WorkspaceMembership` 行；Role 只留差异标签 `[:owner, :admin, :tutor, :volunteer, :learner]`。
2. `/join open` 入座 = 无标签 membership（`admit_member(user_id, ws_id, [])` → 只建 membership 不建 MembershipRole，`membership_context.ex:416-417` 已支持空列表语义，注释「决策 6：无预授权角色待 Owner 手动 assign」）。
3. 注册自动入 2046 = 无标签 membership（`membership_context.ex:317` `[:member]` → `[]`）。
4. `JoinRequest.approve` 默认角色 `[:member]` → `[]`（`join_request.ex:162-165`）；Invitation 预授权角色传入空时同样无标签（`invitation.ex:580-586`，预授权列表默认即空）。
5. 权限映射页按新模型重做：member 不再是行，所有角色行标注「成员基准 + 差异标签」语义（B6 根治）。
6. `learner` 标签保留（它有真实语义：学习 run 的 StepRole 配置、enrolled_learner 判定），但不再是「open 入座的默认角色」。

**非目标**：
- 不迁移存量数据：存量 `member` / `learner` MembershipRole 行保留原样（见 §6 迁移策略）。
- 不动 StepAuthorization 的 `enrolled_learner?` 判定（`step_authorization.ex:118-130`，它锚定 Enrollment 而非 workspace role，与本次重构正交）。
- 不动 `owner/admin` 管理角色语义（`role.ex:40` `@manage_roles`）。
- 不做 #71 自定义角色能力配置本身，只把地基铺平。

## 2. 已验证事实（scout 取证，file:line 以 HEAD 0f2abac 为准）

### 2.1 数据层
- `Role.role_names/0` 六角色唯一真源：`role.ex:27`（`[:owner, :admin, :member, :tutor, :volunteer, :learner]`），`@role_descriptions` `role.ex:29-36`，`@manage_roles [:owner, :admin]` `role.ex:40`。
- `Role.name` 是 atom 属性 `one_of` 约束（应用层），DB 无 enum/check（migration `20260801084116_add_roles_memberships.exs:41-119`，text name + unique index `(workspace_id, name)` + FK）——**删枚举项零 DB schema 变更**。
- `WorkspaceMembership`：`(workspace_id, user_id)` 唯一（`workspace_membership.ex:150`），无 role 字段；角色经 `MembershipRole`（`membership_role.ex:54` unique `(membership_id, role_id)`）。
- 空 role_names 入座已支持：`membership_context.ex:416-417`（「空 role_names → 建 Membership 不建 MembershipRole」）。

### 2.2 入座路径（四处 admit_member 调用方）
- `/join open`：`workspace.ex:397-402` `admit_member(actor.id, ws_id, [:learner], on_conflict: :idempotent)`；描述文案 `workspace.ex:353-354, 500-501`。
- 注册入 2046：`graphql_schema.ex:424-429` → `admit_to_default_workspace`（`membership_context.ex:314-326`，`[:member]` at :317）。
- JoinRequest.approve：`join_request.ex:158-165` argument `role_names` default `[:member]`，入座 :217-225。
- Invitation.accept：`invitation.ex:577-590`，用 `invitation.preauthorized_role_names || []`（预授权语义，无默认角色）。
- WorkspaceApplication 批准：`workspace_application.ex:215-231` `[:owner]`（申请人成为 Owner，非本重构面）。

### 2.3 能力层
- RBAC 四角色同权已证实：`rbac.ex:104-109` member/tutor/volunteer/learner 仅 `view_workspace + access_invite_only`；owner/admin 全量；PlatformAdmin 特例 `rbac.ex:31-44, 89-97`。
- 契约工件：`priv/rbac_contract.json` 由 `mix cgc2046.gen_rbac_contract` 从单源生成（`mix/tasks/cgc2046.gen_rbac_contract.ex`），CI `--check`（`.github/workflows/ci.yml:62`）+ 后端 golden 测试 `rbac_contract_test.exs:20-46` + 前端契约测试 `web/lib/permissions.contract.test.ts` 双向守卫。
- StepRole 授权链：`step_authorization.ex:53-62`（`MembershipContext.role_names` ∩ step 配置角色，owner/admin 豁免）；**当前无生产 seed 为 Step 配置角色**（grep `allowed_roles` 在 lib/priv 仅 `step_authorization.ex` 自身；StepRole 配置经 AshAdmin/测试，无内置 learner 依赖）。`{:ok, []}` 未配置 = 不限制（`step_authorization.ex:81-83`）——新无标签成员不会因缺角色被误拒。

### 2.4 词汇消费面（member/learner 作为 role 名的全集）
**Backend source**：`role.ex:5-35`（枚举+描述）、`workspace.ex:11, 354, 395, 400, 501`、`rbac.ex:108`、`graphql_schema.ex:1144-1146`（desc）、`priv/graphql/schema.graphql:3568-3569, 3586-3588, 4476-4478, 4928-4930`（SDL 枚举文档）、`priv/rbac_contract.json:86, 95`。
**Migrations（历史，不改）**：`20260802000133_backfill_design_roles.exs`、`20260808000000_create_workspace_profiles.exs:29-34`（历史迁移保持原样，仅在 moduledoc 标注 member 已退役）。
**Web**：`web/lib/graphql/workspace.ts:27-35`（ROLE_NAMES）、`397-422`（labels/badge）、`web/lib/profile.ts:305-323`（weight learner=2/member=1）、`web/lib/permissions.ts:20-22`（矩阵行）、`95-101`（member 行隐藏/learner 正式）、`web/app/w/[slug]/settings/members/page.tsx:11-13, 49-52, 247-275, 433-444`（role filter + PERMISSION_ROLE_ORDER）、`web/lib/workspaces.ts:75-83`（roles.name eq filter）、`web/app/globals.css:1112-1115`（badge）。
**Miniprogram**：`miniprogram/src/pages/workspace/index.tsx:12-13, 146-148`、`miniprogram/src/api/generated/schema.ts`（生成物）、`e2e/REAL_DEVICE_CHECKLIST.md:30-32`。
**SDL/生成物**：`schema.graphql` 四处枚举 desc、`miniprogram/src/api/generated/schema.ts` 生成文件。

### 2.5 测试消费面
- 后端 open 入座断言 learner：`workspace_test.exs:1024-1057, 1225-1268`；membership 系 `membership_test.exs:35-45, 101-117`、`membership_context_test.exs:368-371, 418-420, 511-514`；rbac `rbac_test.exs:25-55`；可见性 `course_visibility_test.exs:124-131`、`event_visibility_test.exs:241-248`；邀请 `invitation_test.exs:90-95, 118, 131, 582, 605`。
- 大量 `learner` 变量名是 fixture 命名（enrollment learner），非 role 断言——只改断言 role 的测试。
- Web：`members/page.test.tsx:121, 313-376`、`permissions/page.test.tsx:62-64, 252-274`、`permissions.test.ts:45, 72-105`、`graphql/workspace.test.ts:106-113`。

## 3. High-Level Technical Design

### U1 Backend：member 退出枚举 + 入座无标签化
1. `role.ex`：`@role_names` 删 `:member` → `[:owner, :admin, :tutor, :volunteer, :learner]`；`@role_descriptions` 同步删；moduledoc 更新（member = membership 天然语义，非角色）。保留一个 `@retired_role_names [:member]` 常量 + `retired_role_names/0`，供迁移与存量读取容错。
2. `rbac.ex`：matrix 删 member 行（能力并入「成员基准」文档说明）；`role_names` 相关能力枚举同步。**member 基准能力（view_workspace/access_invite_only）改为「任意 membership 即有」**：`Rbac.abilities_for/2` 对有 membership 的空标签角色返回成员基准能力（保持能力行为完全不变，只是不再经 member role 判定）。
3. 入座路径四改：
   - `workspace.ex:397-402`：`[:learner]` → `[]`；:353-354, :500-501 描述文案同步（「无预授权角色，Owner 可后续分配」语义）。
   - `membership_context.ex:317`：`[:member]` → `[]`。
   - `join_request.ex:162-165`：default `[:member]` → `[]`（argument 保留，审批方可显式传差异角色）。
   - `invitation.ex` 预授权：不变（空即无标签）；`validate_inviter_role_preauthorization` 对 member 传入报错（枚举外）。
4. `graphql_schema.ex:1144-1146` desc 同步；SDL 重生成（`mix cgc2046.graphql_schema` 或项目 SDL 任务，writer 按 repo 现行方式）。
5. 契约：`mix cgc2046.gen_rbac_contract` 重生成 `rbac_contract.json`（roles 列表去 member；matrix 去行）。
6. 存量容错读取：`MembershipContext.role_names/2` 读到 `name == "member"` 的历史 MembershipRole 行时**继续原样返回**（不炸、不过滤——展示层处理）；`CurrentMembershipInfo` abilities 计算经新基准路径，行为不变。

### U2 迁移：存量 member 标签退役（数据一次到位）
> 深重构拍板「一次到位」包含存量：不迁移 = 永久双词汇。采用**删除 member MembershipRole 行 + 无损回退**：
1. 新迁移 `retire_member_role`（可逆）：
   - 每个 workspace 若无 `member` Role 行则跳过；有则 `DELETE membership_roles WHERE role_id = member role`，再 `DELETE roles WHERE name='member'`（行数记入迁移日志）。
   - 幂等、跨全部租户（roles 表按 workspace 隔离，需全表扫；规模小无性能顾虑）。
   - **不触碰 learner/tutor/volunteer 行**——它们是差异标签继续存在。
2. 回滚 `down`：不重建 member role 行（数据已删不可恢复），只打标记说明——按 AGENTS「不保留兼容层」，member 退役不回头。
3. 迁移后新 seed 路径（`find_default_workspace` / workspace 创建 seed roles）：seed 列表去 member（`workspace_application.ex` / `workspace.ex` 创建逻辑里若显式 seed 六角色，同步改五角色）。
4. dev 库验证：迁移前后 `SELECT count(*) FROM roles WHERE name='member'` / `membership_roles` 关联数对照，写进 writer 报告。

### U3 Web + 权限映射页（B6 根治）
1. `web/lib/graphql/workspace.ts`：`ROLE_NAMES` 去 member；labels/badge 去 member 项；`MANAGE_ROLE_NAMES` 不变。
2. `web/lib/permissions.ts` + 权限映射页（`web/app/w/[slug]/settings/permissions/`）重做展示模型：
   - 基准行「成员（所有工作台成员）」：view_workspace、access_invite_only + 说明「成员资格本身即拥有」。
   - 差异行：tutor/volunteer/learner 合并为一行「成员 + 差异标签（当前能力等同，标签用于工作流步骤授权与分工）」+ owner/admin 管理行。
   - 保留能力×角色矩阵结构（契约测试依赖），member 行删除后 `PERMISSION_ROLE_ORDER` 同步。
3. `web/lib/profile.ts:305-323` role weight：member 权重逻辑改为「无标签 = 基准」，learner/tutor 等标签照旧（存量 learner 行仍显示「学员」徽章——历史事实，不伪装）。
4. 成员管理页（`settings/members/`）：role filter 去 member 选项；存量 member 标签行显示为「成员（无标签）」或直接不显示标签（UX 决策：**显示空标签状态**——与无标签新成员一致）；assign roles 下拉去 member。
5. `web/lib/workspaces.ts:75-83` roles.name eq filter：member 值不再下发（后端枚举外），前端类型同步。
6. `web/app/globals.css` badge：member 样式保留（存量显示兼容）或删（若 U2 已清库则删；**删**，U2 保证库里无 member 行）。
7. miniprogram `workspace/index.tsx` 词汇同步（ROLE 标签映射）；`REAL_DEVICE_CHECKLIST.md` 文案更新。

### U4 测试
1. 后端改断言：open 入座 → membership 存在 + `role_names == []`（`workspace_test.exs:1024-1057` 等）；注册入 2046 同理；join_request approve 默认无标签；能力测试：无标签成员 abilities == 旧 member abilities（钉住「能力不变」契约）。
2. 新增守卫：`rbac_contract_test` 自动经单源断言（无需改）；加一条「member 不在 role_names」显式断言防回潮。
3. Web：`permissions.contract.test.ts` 随契约工件自动红→绿；members/permissions page 测试更新；`workspace.test.ts` ROLE_NAMES 断言。
4. e2e（agent-browser，结构断言）：/join open → 成员列表出现 + 无角色标签；注册 → 2046 成员无标签；权限映射页新布局断言（基准行 + 差异标签行存在，无 member 独立行）。

### U5 文档同步
- `CONTEXT.md` 权限契约节（:149-151 附近）与角色相关定义更新为「membership = 成员资格；Role = 差异标签（五角色）」。
- `docs/adr/` 若有角色模型 ADR 则补退役记录（scout 未见专门 ADR，writer 确认；无则新增简短 ADR-00XX：member 语义化）。
- `rbac_contract.json` 重生成 + `README`/`CONTRIBUTING` 无需变（命令不变）。

## 4. 风险与预案

| 风险 | 概率 | 预案 |
|---|---|---|
| 存量 DB 里 member MembershipRole 删除后某处代码仍 `Enum.find(roles, name==member)` 返回 nil 崩溃 | 中 | U1.6 容错读取 + 全量测试；grep `:member` 残留（writer 自查清单） |
| StepRole 配置了 member 的 workspace（AshAdmin 手配）授权失效 | 低 | 当前无生产 seed；迁移日志输出受影响 step 数；StepRole 空 = 不限制语义兜底 |
| 小程序生成 schema 漂移 | 中 | U3.7 同步生成或手改；CI miniprogram check 兜底 |
| `admit_member` 空 role_names 并发幂等路径（`workspace.ex:381-386` transaction?: false）行为变化 | 低 | 路径本身不变（`membership_context.ex:416-428` 已有空列表分支 + 并发 unique 处理），测试已覆盖 |
| 权限映射页重做引入新误导 | 中 | U4.4 e2e 断言新布局语义；advisor 重点审展示模型 |

## 5. 验收标准

1. `Role.role_names` == `[:owner, :admin, :tutor, :volunteer, :learner]`；`rbac_contract.json` 同步；CI 全绿。
2. `/join open`（open 策略工作台）新入座：membership 存在、无 MembershipRole 行、meWorkspaces 能力 == 旧 member 能力。
3. 新注册用户：2046 membership 无标签、能力同上。
4. JoinRequest approve（默认参数）：无标签入座。
5. 存量 member role 行全部退役（迁移后 count==0，全租户）；learner/tutor/volunteer/owner/admin 行原样。
6. 权限映射页：无 member 独立行；「成员基准 + 差异标签」模型；契约测试绿。
7. 全量自查绿：backend format/compile/test ×2 seeds、SDL 零手改漂移（重生成后 diff 仅预期枚举变化）、web typecheck/lint/test/build、miniprogram 生成物同步。
8. e2e：open 入座无标签 + 注册无标签 + 权限映射页新布局，三组结构断言过。

## 6. 实施顺序（writer 契约）

U1 backend（枚举+入座+能力基准+SDL+契约）→ U2 迁移 → U3 web/miniprogram → U4 测试 → U5 文档 → 自查全套 → 本地 commit（不 push）→ 报告 `/tmp/cgc_2046-writer17-report.md`。

## 7. Assumptions（writer 验证，冲突即停）

1. `Rbac.abilities_for/2` 现对「membership 存在但 roles 空」的返回路径存在或可最小新增（scout 证实 CurrentMembershipInfo 已有空 abilities 分支 `current_membership_info.ex:42-80`——admin 非成员 branch；成员空标签分支需 writer 落地验证）。
2. workspace 创建路径若 seed 六角色有显式列表（`workspace_application.ex` / workspace create），改为五角色；`backfill_design_roles` 历史迁移不动。
3. miniprogram generated schema 可由项目任务重生成或手改（repo 有 `miniprogram/src/api/generated/`，writer 找现行生成方式；找不到则手改 + 报告注明）。
4. 权限映射页测试（`permissions/page.test.tsx`）重写幅度可控（矩阵结构保留）。
