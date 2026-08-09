# Plan 005: 让认证提交原子化并隔离账号本地状态

> **Executor instructions**: 严格按步骤执行。先加会失败的回归测试，再做最小运行时修改。
> 不改变后端、cookie 名称、GraphQL shape 或“通知中心是本地记录”的 v1 决策。
> 遇到 STOP 条件立即停止，不要用兼容 fallback 保留旧全局 key。
> 完成后更新 `advisor-plans/README.md` 状态行，除非 reviewer 明确由其维护。
>
> **Drift check（第一条命令）**:
> `git diff --stat f1fd4aa..HEAD -- miniprogram/src/api/client.ts miniprogram/src/api/real.ts miniprogram/src/state miniprogram/src/pages/join/index.tsx miniprogram/tests miniprogram/vitest.config.ts miniprogram/package.json`
> 004 会新增 Vitest/config/API tests，001/002 会新增 policy tests；这些只有在对应方案状态为 DONE 且与其
> Scope 一致时可接受。其他实现漂移即 STOP。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `advisor-plans/004-establish-api-contract-tests.md`
- **Category**: security / bug
- **Planned at**: commit `f1fd4aa`, 2026-08-09

## Why this matters

当前登录 cookie 在响应被判定成功前就持久化，sign-in mutation 成功但 session hydration 失败时也不会回滚；
UI 因而可以显示“登录失败”，设备却已经切换 token。本地通知、最近报名和 bearer-like invitation scene
又没有统一账号边界，401/换号后可能暴露前一账号数据或让下一账号消费遗留邀请。
本方案建立单一账号状态模块：成功响应后才提交 token，session 失败全量回滚，通知按 active user 命名空间
隔离，scene 一进入 Join 页就从持久 storage 消费到路由/内存。

## Current state

- `miniprogram/src/api/client.ts:8` 在模块加载时读取 token；`:41-49` 的过期清理只处理 token 与 Workspace Tab。
- `miniprogram/src/api/client.ts:91-113` 当前顺序是：捕获 cookie → 检查 HTTP → 检查 GraphQL errors →
  检查 data：

  ```ts
  if (options.captureAuthCookie) {
    const token = extractAuthToken(response.cookies, response.header as Record<string, unknown>)
    if (token) setAuthToken(token)
  }
  if (response.statusCode < 200 || response.statusCode >= 300) { /* throw */ }
  if (response.data.errors?.length) { /* throw */ }
  if (!response.data.data) { /* throw */ }
  ```

- `miniprogram/src/api/real.ts:72,103-110` 用全局 `cgc.local_notifications` 存通知。
- `miniprogram/src/api/real.ts:183-199` sign-in 捕获 token 后调用 `getSession()`；第二步失败没有 rollback。
- `miniprogram/src/api/real.ts:201-211` 显式 sign-out 清通知/最近报名，但不清 `pendingScene`；401 路径也不清。
- `miniprogram/src/app.tsx:7-12` 把 scene 持久化；`miniprogram/src/pages/join/index.tsx:10-12,27-33`
  读取后只在入座成功时删除，因此取消、换号或失败后会遗留。
- `miniprogram/src/state/storage.ts:1-4` 已集中声明 `lastEnrollment`、`pendingScene` key；继续复用，不复制字符串。
- `miniprogram/src/state/workspaceTab.ts:14-17` 是现有“清 storage + 发 event”惯例，新的状态模块应同样保持窄职责。
- 已决边界：通知中心继续是本地记录；本方案只做账号隔离。手机号存储、phoneCode backend 契约、
  真机 cookie 提取风险均不在本方案。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 前置测试 | `cd miniprogram && pnpm test:unit` | exit 0；004 已 DONE |
| 红测 | `pnpm exec vitest run tests/api-client.test.ts tests/account-state.test.ts tests/real-auth.test.ts` | 实现前仅新增回归用例失败，失败原因与本方案一致 |
| 定向绿测 | 同上 | 实现后 exit 0，无 skip/todo |
| 全量 unit | `pnpm test:unit` | exit 0 |
| 类型检查 | `pnpm typecheck` | exit 0，无错误 |
| 合规 | `pnpm check:licenses` | exit 0；本方案不新增依赖 |
| 三端构建 | `pnpm build:all` | exit 0 |

## Scope

**In scope**:

- `miniprogram/src/state/accountState.ts`（创建）
- `miniprogram/src/api/client.ts`
- `miniprogram/src/api/real.ts`
- `miniprogram/src/pages/join/index.tsx`
- `miniprogram/tests/api-client.test.ts`
- `miniprogram/tests/account-state.test.ts`（创建）
- `miniprogram/tests/real-auth.test.ts`（创建）
- `miniprogram/vitest.config.ts`
- `miniprogram/package.json`（只让 `test:unit`/Vitest 包含新增测试；不改依赖）
- `advisor-plans/README.md`（只更新状态行）

**Out of scope**:

- backend schema/resolver、GraphQL operations/generated 文件、cookie 名称 `cgc_token` 或 endpoint。
- `miniprogram/src/app.tsx` 的 warm-start scene 生命周期（F05，单独修复）；本方案只安全消费已收到的 scene。
- 通知服务端化、同步/推送、手机号字段、`getPhoneNumber code` 契约。
- 报名结果 route-id 漂移（F07）和审批展示（F06）。
- UI/CSS、导航信息架构、平台裁剪、任何 AppID/secret/token/.env 值。
- 保留读取旧全局 notification key 的兼容层；应一次清理旧 key，然后只读用户命名空间。

## Git workflow

- Branch: `advisor/005-make-auth-state-atomic`
- 建议分两个提交：
  1. `test(miniprogram): 锁定认证原子性与账号隔离合同`
  2. `fix(miniprogram): 原子提交认证并隔离本地状态`
- 未经 operator 指示不得 push 或开 PR。

## Steps

### Step 1: 扩展 Vitest 输入但先不改运行时

把 `vitest.config.ts` 的 include 和 `package.json:test:unit` 扩展到三份 Vitest 文件：

- `tests/api-client.test.ts`
- `tests/account-state.test.ts`
- `tests/real-auth.test.ts`

保留 001/002 的 Node tests，禁止用 `|| true`、skip 或 todo。

**Verify**: `pnpm test:unit` → 在新测试文件创建前仍运行 004 基线；不要提交一个指向不存在文件的中间状态。

### Step 2: 写认证提交顺序的红测

在 `tests/api-client.test.ts` 复用 004 的 Taro mock，新增：

1. 401 response 同时携带 `captureAuthCookie` cookie 时，最终 token 为空且 cookie 从未成为可观察成功状态。
2. 200 response 带 GraphQL auth error + cookie 时，不提交新 token，并清旧认证状态。
3. 200 response 带普通 GraphQL error + cookie 时，不提交新 token，但保留旧 token。
4. 200 response 缺 data + cookie 时，不提交新 token。
5. 只有 2xx、无 errors、有 data 时才提交 candidate token。

对“从未提交”不要只看最终值；spy `Taro.setStorageSync`，断言失败路径没有以 auth key 写入 candidate fixture。

**Verify**:

```bash
pnpm exec vitest run tests/api-client.test.ts
```

预期：修改实现前，至少普通 GraphQL error/空 data 携 cookie 用例失败；失败位置在 `client.ts:91-94`，
不是 mock 配置错误。记录红测输出摘要后继续。

### Step 3: 创建单一账号本地状态模块与红测

创建 `src/state/accountState.ts`，目标 public API 固定为：

```ts
export function activateAccount(userId: string): void
export function getActiveAccountId(): string | null
export function clearAccountState(options?: { clearPendingScene?: boolean }): void
export function appendLocalNotification(title: string, body: string): void
export function readLocalNotifications(): NotificationItem[]
export function takePendingScene(routeScene?: string): string
```

实现约束：

- active user key：`cgc.active_user_id`。
- notification key 只允许 `cgc.local_notifications.<userId>`；旧 `cgc.local_notifications` 只删除，永远不读。
- `activateAccount` 切换 user 时清 `STORAGE_KEYS.lastEnrollment`，设置 active ID，删除旧全局 notification key；
  不删除另一个 user 的 namespaced notifications，也不碰当前登录流程携带的 pending scene。
- `readLocalNotifications` 无 active user 时返回 `[]`；`appendLocalNotification` 无 active user 时不得写全局 key。
- `clearAccountState` 删除 active user 的 notifications、active ID、旧全局 notification key、lastEnrollment；
  仅 `clearPendingScene: true` 时删除 pending scene。
- `takePendingScene(routeScene)` 优先 route 参数，否则读 storage；返回前始终删除持久 pendingScene。
  scene 之后只存在 Join 页面 state/登录 returnUrl，不继续作为跨会话 bearer 持久化。
- 通知最大 50 条、最新在前、`NotificationItem` shape 保持现有实现。

创建 `tests/account-state.test.ts`，mock Taro storage，至少覆盖：A/B 两账号通知互不可见、切换账号清
lastEnrollment、旧全局 key 不可读且被清、clear true/false 的 scene 边界、route scene 优先和 take 后 storage 为空。

**Verify**: `pnpm exec vitest run tests/account-state.test.ts` → 新模块实现后 exit 0。

### Step 4: 成功校验后才提交 candidate token

修改 `src/api/client.ts`：

1. response 返回后可以提取 `candidateToken` 到局部变量，但不得立即调用 `setAuthToken`。
2. 保持 HTTP status → GraphQL errors → data 三层校验与现有 error shape。
3. 三层全部成功后、return data 前，才提交 candidate token。
4. `clearExpiredAuthentication` 除 token/Workspace 外调用
   `clearAccountState({ clearPendingScene: true })`。
5. 非认证 HTTP/GraphQL/network error 不清旧 token/账号状态，也不提交 candidate。

不要把 cookie parser 改成新协议，不处理真机 cookie 风险；只改 commit point。

**Verify**:

```bash
pnpm exec vitest run tests/api-client.test.ts
```

预期：004 全部基线 + Step 2 新用例全通过。

### Step 5: 把 Real API 迁到账号状态模块

修改 `src/api/real.ts`：

- 删除 `NOTIFICATION_KEY`、`storedNotifications`、`addNotification`，改用
  `appendLocalNotification` / `readLocalNotifications`。
- `getSession()` 成功且 `data.me` 非空时，在暴露 session 前调用 `activateAccount(data.me.id)`。
- `getSession()` 发现没有 token 时，清理残留账号状态但用 `clearPendingScene: false`，让扫码→登录交接继续。
- `signIn()` 在开始新平台登录事务前清旧 token、Workspace 和旧账号状态，但保留 pending scene；
  mutation/data/cookie 成功后再 hydrate session。
- hydrate session 任意失败：清新 token、Workspace、账号状态（仍保留当前 route 持有的 scene）并 rethrow，
  UI 显示失败与设备状态保持一致。
- `signOut()` finally 使用同一 clear path，并传 `clearPendingScene: true`；删除散落的 Taro remove 调用。
- 审批/授权写本地通知的标题、正文、50 条上限保持不变。

创建 `tests/real-auth.test.ts`，用 Vitest mock client/state，至少覆盖：

1. sign-in mutation 成功并得到 token，但 session 请求 reject → token/Workspace/account 全回滚。
2. 完整成功 → `activateAccount` 收到 session user ID，返回原 session。
3. sign-out GraphQL reject → finally 仍清 token、Workspace、账号状态和 pending scene。
4. 无 token getSession → 返回匿名 snapshot，清残留 account 但保留 pending scene。

**Verify**: `pnpm exec vitest run tests/real-auth.test.ts` → 全部通过，无真实请求。

### Step 6: 让 Join 页一次性取得 scene

修改 `src/pages/join/index.tsx:10-12`，用 `takePendingScene(router.params.scene)` 初始化 state，删除直接
`Taro.getStorageSync`。保留现有 returnUrl 中显式 scene：未登录跳转后仍可恢复；入座成功时原有
`removeStorageSync` 已变成多余，应删除，不留兼容路径。

不要改页面文案、布局、路由或 warm-start App lifecycle。

**Verify**:

```bash
rg -n "takePendingScene" src/pages/join/index.tsx src/state/accountState.ts
rg -n "getStorageSync.*pendingScene|removeStorageSync.*pendingScene" src/pages/join/index.tsx
```

预期：第一条两文件命中；第二条无命中。

### Step 7: 跑全量确定性门禁

```bash
pnpm exec vitest run tests/api-client.test.ts tests/account-state.test.ts tests/real-auth.test.ts
pnpm test:unit
pnpm typecheck
pnpm check:licenses
pnpm build:all
pnpm check:diversion
git diff --check
git status --short
```

**Verify**: 前八条 exit 0；status 只有 Scope 文件和索引。三端 build 后必须重新跑零导流，确保新 state key/
错误文案没有破坏裁剪端红线。

## Test plan

- `api-client.test.ts`：失败 response 携 cookie 不提交；成功 response 才提交；auth/non-auth 清理差异。
- `account-state.test.ts`：A/B notification 隔离、legacy global key 清理、lastEnrollment 切号清理、scene take/clear。
- `real-auth.test.ts`：sign-in 两阶段事务、session hydration rollback、sign-out finally、anonymous residual cleanup。
- 现有 domain/license/diversion tests 全保留；三端 build + diversion 是集成回归。
- 不需要 browser/真机：没有 UI 样式变化；真机 cookie extraction 仍按现有 checklist 单独验证。

## Done criteria

- [ ] candidate auth cookie 只在 2xx + 无 GraphQL errors + data 存在后写 storage。
- [ ] session hydration 失败后 `getAuthToken()` 为 null，Workspace/active account 已清。
- [ ] `rg -n "cgc\.local_notifications['\"]" miniprogram/src` 无旧全局 key 读取；仅允许迁移清理常量。
- [ ] A/B 账号通知隔离测试、legacy key 不可读测试、pending scene take 测试全通过。
- [ ] Join 页不再直接读/删 pendingScene storage，route scene 登录续接测试通过。
- [ ] `pnpm test:unit`、`pnpm typecheck`、`pnpm check:licenses`、`pnpm build:all`、
  `pnpm check:diversion`、`git diff --check` 全部 exit 0。
- [ ] 没有新增依赖，没有修改 GraphQL/backend/UI/CSS/项目标识配置。
- [ ] `advisor-plans/README.md` 的 005 状态已更新。

## STOP conditions

立即停止并报告，如果：

- 004 未 DONE，无法可靠 mock Taro request/storage 或重置 module-level token。
- backend 的 sign-in 成功合同允许 2xx errors/data 混合且必须提交 cookie；需先明确服务端契约，不能猜。
- session hydration 失败必须保留 token 的产品决策已被正式记录；本方案选择的是 rollback 语义。
- 按账号命名 storage key 会超过目标平台限制或 user ID 不是稳定、非敏感的内部 ID。
- 扫码→登录→返回只能依赖持久 pendingScene、returnUrl 实际不保留 scene；先用测试证明后请求边界决策。
- 修改要求触碰 backend/GraphQL operations、通知服务端化、手机号契约或其他 Scope 外文件。
- 任一步验证在一次合理修正后仍失败。

## Maintenance notes

- 以后新增任何账号本地数据都必须通过 `accountState.ts` 命名空间或 clear path，不再散落裸 storage key。
- reviewer 重点检查 token commit point、hydrate rollback、auth/non-auth error 差异和 pending scene 的登录续接。
- warm-start scene（F05）、报名结果 route-id（F07）和审批身份展示（F06）仍是独立后续，勿在本 PR 扩 scope。

