# Plan 2026-08-20-007 · #215：manage_events 进 RBAC 能力矩阵，替代前端角色名推断

## 背景

内容管理域（events/courses/pricing/sponsorship）前端权限判断用角色名硬编码：`canManageEvents(ws)` = `myRoleNames ∈ MANAGE_ROLE_NAMES`（owner/admin）（`web/lib/events.ts:41-43`）——违反「消费端不复写权限语义」契约；能力模型 7 能力中无 `manage_events`。后端 policy 兜底存在（Event/Course create/update → `WorkspaceActorIsOwnerOrAdmin` → `Role.manage_roles/0`），无安全洞，纯一致性收敛。

Scout 核心结论：RBAC 单源加 `:manage_events` 后，`matrix/0`（rbac.ex:103-118）、`abilities_for/2`（:62-90）、`myAbilities`（CurrentMembershipInfo:36-40）、`permissionMatrix`（graphql_schema.ex:26-34）**全部自动带出，零 resolver/calc 改动**。前端展示/测试面由 golden-file 双向契约强制同步。

## 决策

- 后端：`:manage_events` 插入 `@abilities` 管理能力组（`update_join_policy` 之后、`create_workspace` 之前——顺序=展示顺序），同时进 `@manage_abilities`（owner/admin 自动 true，经 `roles_can?` → `Role.manage_role?/1`）。
- 前端：`canManageEvents` 改签名为消费 `myAbilities`（`myAbilities.includes("manage_events")`），五个消费点全改；**保留** `MANAGE_ROLE_NAMES`（约束「可管理角色」语义，与 events 门控无关，permissions.contract.test:109-124 守卫）。
- 语义校验（scout 已核）：policy 面 `Role.manage_roles/0` = [owner,admin] 与矩阵 manage_events=true 完全一致，**无 policy 语义变化**；非成员平台管理员对 manage_events 无豁免（CurrentMembershipInfo manage 分支自动满足，与 platform_admin.ex #66 P2 双面契约一致）。

## 实施单元

### U1 backend 单源（`rbac.ex`）

1. `@type ability`（:14-23）+ `@abilities`（:26-34）+ `@manage_abilities`（:36）加 `:manage_events`。
2. moduledoc 能力表（:19-33）与 `:104`「五角色 × 七能力」措辞同步（→八）；`graphql_schema.ex:21` @desc、`platform_admin.ex` moduledoc:12-16 能力列举同步补 manage_events。

### U2 golden-file 重生成

`mix cgc2046.gen_rbac_contract`（重生成 `backend/priv/rbac_contract.json`：abilities 8 项 + matrix 8 列）；backend 编译触发 `schema.graphql` 自动重生成（勿手改）；miniprogram generated 不在手改范围（CI codegen 管，本期不动小程序源）。

### U3 backend 测试字面断言更新

- `rbac_test.exs:8-36`（矩阵 owner/admin 行补 manage_events=true）、`:40-107`（owner 6→7 项精确列表、union、unions-with-matrix）。
- `graphql_rbac_test.exs:126-180`（permissionMatrix 逐能力补 field）、`:207-215`（myAbilities 'all seven'→八）。
- `workspace_test.exs:692-818`（owner :711-719 精确列表、member :744、平台管理员非成员 :784-789、outsider :816）。

### U4 web 前端门控

1. `web/lib/events.ts:41-43`：`canManageEvents` 改消费 abilities（签名变更为 `ws.myAbilities` 判定；`Workspace` 类型已有 `myAbilities?:` workspace.ts:83）。
2. 五消费点改传 abilities：`offering-pages.tsx:219/:466/:1257`、`pricing/page.tsx:26`、`sponsorship/page.tsx:30`。
3. 展示三件套：`web/lib/graphql/permissions.ts:27-35`（RbacAbility union 补 `'manage_events'`）、`web/lib/permissions.ts:30-57`（PERMISSION_ABILITIES 补标签项）、`web/messages/{zh-CN:1455-1485,en}.json`（ability.manage_events label/description 成对）。

### U5 web 测试/fixture

- `offering-pages.test.tsx:42-46` mock 改 abilities + OWNER_WORKSPACE fixture（:109-118）补 `myAbilities`；`invite-batch.test.tsx:33-34/:137` 同步。
- `permissions/page.test.tsx`：TEST_MATRIX（:24-83）补行、计数断言 7→8（:341）、文案断言（:242/:274/:397）。
- `web/lib/permissions.test.ts` fixture（:18-45）补 manage_events 保真。
- `workspace-nav.ts` 恒显导航无需改（scout：events/courses/sponsorship/pricing 无 ability 门控）。

## 验收标准

1. backend：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿（含 rbac_contract_test 对重生成 golden-file 的 --check 一致）。
2. web：`pnpm typecheck / lint / test / build` 全绿（含 permissions.contract.test.ts 双向守卫）。
3. 权限映射页展示 8 能力行含 manage_events（owner/admin ✓，其余 ✗）。
4. 前端五门控点全部经 myAbilities，全库 grep 无 `canManageEvents` 角色名路径残留。

## 非目标

- 不改 Event/Course/Sponsorship/Pricing 的 Ash policy（语义已一致）。
- 不删 `MANAGE_ROLE_NAMES`（独立语义，另有守卫与消费方）。
- 不动 miniprogram 源码（generated 由 CI codegen 漂移门禁线 #218 管）。
- 不给 tutor/volunteer 开放内容管理（矩阵维持 owner/admin）。

## 风险

| 风险 | 缓解 |
|---|---|
| golden-file 漏重生成/漏提交 → CI 双端红灯 | U2 显式步骤 + 验收 1/2 契约测试 |
| 字面断言遗漏（backend 三文件 × 多处） | U3 全清单化（scout 已逐处定位） |
| canManageEvents 签名变更致 mock/fixture 假红假绿 | U5 显式清单 |
| @abilities 顺序与前端标签/golden 数组不一致 | 插入点固定（管理组内），三面同序 |
| 文档措辞漂移（七能力→八） | U1.2 措辞清单 |

## 关联

- Issue #215；Scout 报告 `agent://Scout215`（2026-08-20）
- 双面契约：`platform_admin.ex:12-16`；golden 守卫链 ci.yml:62
- 后续：解锁 #219 权限签核包（本线是其 blocker）
