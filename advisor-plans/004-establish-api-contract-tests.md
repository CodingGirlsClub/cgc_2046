# Plan 004: 建立可故障注入的 API 与认证边界测试

> **Executor instructions**: 逐步执行并确认每个验证结果。本方案只建立 characterization/regression 基线，
> 不修改运行时合同；若测试暴露当前失败，先报告，不要在本方案顺手修 client。
> 完成后更新 `advisor-plans/README.md` 状态行，除非 reviewer 明确由其维护。
>
> **Drift check（第一条命令）**:
> `git diff --stat f1fd4aa..HEAD -- miniprogram/package.json miniprogram/pnpm-lock.yaml miniprogram/tests miniprogram/src/api/client.ts miniprogram/src/state/workspaceTab.ts`
> 001 会按计划改 package/lock 和新增 license policy test；如果 001 已是 DONE，只有其方案明确列出的变化可接受。
> 其他不一致即 STOP。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `advisor-plans/001-license-gate-fail-closed.md`, `advisor-plans/002-diversion-gate-fail-closed.md`
- **Category**: tests
- **Planned at**: commit `f1fd4aa`, 2026-08-09

## Why this matters

小程序所有真实请求、token 捕获、401 清理和 GraphQL 错误判定都集中在 `src/api/client.ts`，但现有五条
unit 只覆盖纯领域格式化，mock E2E 会绕过真实 transport。Node 的 strip-only TS runner又不能加载
constructor parameter property，因此不能简单 import client。引入仓库已使用的 Vitest 后，可以在 Node 中
稳定转换 TS、定义 Taro 编译常量并 mock 存储/请求，给后续认证原子性与账号隔离提供明确安全网。

## Current state

- `miniprogram/tests/domain.test.ts:1-43` 是唯一 unit 文件，使用 `node:test`，覆盖 5 个纯函数合同。
- `miniprogram/package.json:18` 当前是：

  ```json
  "test:unit": "node --experimental-strip-types --test tests/*.test.ts"
  ```

  如果 001 已完成，它还会包含 `.test.mjs` policy tests；本方案必须保留这些测试。
- 只读探针直接 import `src/api/client.ts` 返回 `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`，原因是
  `miniprogram/src/api/client.ts:21-26` 的 constructor parameter properties。
- `miniprogram/src/api/client.ts:56-67` 从 `cookies`、`set-cookie`、`Set-Cookie` 提取 token；`:70-113`
  构造请求、处理 401/GraphQL errors/空 data。
- `miniprogram/src/api/client.ts:75-78` 的 E2E mock 分支直接返回 mock transport，不能验证真实请求边界。
- `miniprogram/src/state/workspaceTab.ts:4-21` 用 Taro storage + eventCenter；API client 的 401 路径会调用它。
- 同仓库 `web/package.json` 已使用 Vitest 4.1.10，Node 要求 `>=22`、pnpm 10.28.2；小程序 CI 当前是 Node 24 + pnpm 10。
- Vitest registry license 是 MIT；其传递依赖仍必须由完成后的 001 严格扫描，不能只看 direct package。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 前置门禁 | `cd miniprogram && pnpm check:licenses` | exit 0；001 已 DONE |
| 核验 runner | `pnpm view vitest@4.1.10 version license --json` | version `4.1.10`、license `MIT` |
| 安装 | `pnpm add -D vitest@4.1.10 --save-exact` | exit 0；只新增 Vitest 依赖树 |
| API tests | `pnpm exec vitest run tests/api-client.test.ts` | exit 0；全部通过 |
| 全量 unit | `pnpm test:unit` | exit 0；Node tests 与 Vitest tests 都通过 |
| 类型检查 | `pnpm typecheck` | exit 0，无错误 |
| 合规 | `pnpm check:licenses` | exit 0；新增完整传递树全部获准 |

## Suggested executor toolkit

- 编写 mock 前可查 Vitest 4 官方 `vi.hoisted`、`vi.mock`、`vi.resetModules` 文档；不要引入 Jest 兼容层。
- Taro 运行时行为以本仓库 `src/api/client.ts` 和 `src/state/workspaceTab.ts` 为准，不访问真实平台 API。

## Scope

**In scope**:

- `miniprogram/vitest.config.ts`（创建）
- `miniprogram/tests/api-client.test.ts`（创建）
- `miniprogram/package.json`
- `miniprogram/pnpm-lock.yaml`
- `advisor-plans/README.md`（只更新状态行）

**Out of scope**:

- `miniprogram/src/api/client.ts`、`real.ts`、`mockTransport.ts`：本方案先测试现状，不修运行时。
- `miniprogram/src/state/**`、页面/UI、GraphQL operations/generated files。
- `.github/workflows/ci.yml`：它已运行 `pnpm test:unit`；本方案让该命令包含新测试即可。
- 真实网络、真实 cookie、AppID/secret/token、`.env` 和 `project.config.json`。
- React component renderer、jsdom、Testing Library；API client 测试只需 Node environment。

## Git workflow

- Branch: `advisor/004-establish-api-contract-tests`
- 建议提交：`test(miniprogram): 覆盖 API 认证失败合同`
- 未经 operator 指示不得 push 或开 PR。

## Steps

### Step 1: 确认许可证前置并安装精确 Vitest

先确认 `advisor-plans/README.md` 的 001、002 状态都是 DONE，并运行：

```bash
cd miniprogram
pnpm check:licenses
pnpm view vitest@4.1.10 version license --json
pnpm add -D vitest@4.1.10 --save-exact
```

不要使用 caret，不要顺手升级 Taro/TypeScript/Webpack。

**Verify**:

```bash
node -e "const p=require('./package.json'); if(p.devDependencies.vitest!=='4.1.10') process.exit(1)"
pnpm check:licenses
git diff -- package.json pnpm-lock.yaml
```

预期：前两条 exit 0；diff 只有 Vitest direct dependency、其锁文件节点，以及 001 已有变化。

### Step 2: 创建最小 Node Vitest 配置

创建 `miniprogram/vitest.config.ts`：

- `test.environment = 'node'`。
- alias `@` 精确指向 `miniprogram/src`，与 `config/index.ts:17-19` 一致。
- `clearMocks` 与 `restoreMocks` 开启。
- 用 `define` 提供 `__E2E_MOCK__ = false` 和一个不可路由的测试 URL
  `__GRAPHQL_ENDPOINT__ = "https://example.invalid/graphql"`；不得读取真实 `.env`。
- 只 include `tests/api-client.test.ts`，避免 Vitest 尝试接管仍由 `node:test` 运行的 domain/policy 文件。
- 不启用 globals；测试显式从 `vitest` import `describe/it/expect/vi/beforeEach`。

**Verify**:

```bash
pnpm exec vitest --version
```

预期：exit 0，输出 Vitest `4.1.10`。配置的 alias/define 在 Step 3 创建测试后由真实 import 验证，
不使用“no test files”作为成功信号。

### Step 3: 建立可重置的 Taro mock

在 `tests/api-client.test.ts` 顶部用 `vi.hoisted` 创建单一 mock 对象，并 `vi.mock('@tarojs/taro', ...)`。
mock 至少实现：

- `request: vi.fn()`；每个 test 自行 resolve/reject。
- `getStorageSync`、`setStorageSync`、`removeStorageSync`，背后使用每 test 清空的 `Map<string, unknown>`。
- `eventCenter.trigger/on/off` 为 spies/no-op，足以覆盖 `clearWorkspaceTab`。

每个 test 的 `beforeEach` 必须：清 Map、重置 request/event spies、调用 `vi.resetModules()`，然后动态 import
`../src/api/client`。这是必要的，因为 `client.ts:8` 在模块加载时把 storage token读入 module-level variable。
不要把 token value 写进 snapshot；测试使用显然是 fixture 的短字符串。

**Verify**: `pnpm exec vitest run tests/api-client.test.ts` → 至少能加载 client，不出现 Taro/alias/global 未定义错误。

### Step 4: 覆盖成功请求与 cookie 形态

新增表驱动用例：

1. storage 初始 token 会生成 `Authorization: Bearer <fixture>`；无 token 时不发送 Authorization。
2. 成功 2xx + `options.captureAuthCookie` 从 `response.cookies` 保存 token。
3. 分别从小写 `set-cookie` 和大写 `Set-Cookie` 保存 token；array/string 都覆盖。
4. URL 固定是 Vitest define 的 `.invalid` 地址，method POST、timeout 15000、data 含 query/variables。
5. 2xx data 返回调用方，不泄漏完整 response。

通过 mock 的 `request.mock.calls` 做结构断言，不依赖真实 Taro 类型实现。

**Verify**: `pnpm exec vitest run tests/api-client.test.ts -t "成功|cookie|Authorization"` → 匹配用例全通过。

### Step 5: 覆盖失败分类与状态清理

新增用例：

1. HTTP 401 抛 `GraphQLRequestError`，statusCode 401，token 与 Workspace visibility key 被清除。
2. GraphQL error 的 `code` 或 `extensions.code` 为 `unauthorized`/`unauthenticated`/`not_authenticated`
   时清认证；用 `it.each` 覆盖三种值和两种字段位置。
3. HTTP 500、普通 GraphQL validation error 抛错但保留现有 token。
4. 2xx、无 errors、但缺 `data` 时抛“服务端未返回数据”。
5. `Taro.request` 网络 reject 原样传播并保留 token。
6. `isAuthenticationError` 对普通 Error 返回 false。

本方案不新增“错误响应 cookie 不得落盘”断言，因为当前实现不满足；该安全回归由 005 在修代码时先加红测。

**Verify**: `pnpm exec vitest run tests/api-client.test.ts` → 全部通过，无 todo/skip。

### Step 6: 把 API tests 接入现有 CI 入口

保留 `test:unit` 这个 workflow 已调用的唯一入口，将其改为顺序执行：

1. 001 留下的 Node tests（`tests/*.test.ts`/`tests/*.test.mjs`，但排除 `api-client.test.ts`，避免 Node runner
   再次直接导入 client）；
2. `vitest run tests/api-client.test.ts`。

最稳妥的脚本形态是显式列出 Node 文件，而不是让两个 runner 抢同一 glob，例如：

```json
"test:unit": "node --experimental-strip-types --test tests/domain.test.ts tests/diversion-policy.test.ts tests/license-policy.test.mjs && vitest run tests/api-client.test.ts"
```

如果 001/002 中某个测试文件尚不存在，不要保留一个指向不存在文件的命令；先按已 DONE 的依赖实际文件列出，
并在后续方案落地时同步追加。禁止用 `|| true`。

**Verify**:

```bash
pnpm test:unit
pnpm check:licenses
pnpm typecheck
git diff --check
git status --short
```

预期：前四条 exit 0；status 只包含 Scope 文件和索引，运行时源码没有 diff。

## Test plan

- 新文件：`miniprogram/tests/api-client.test.ts`。
- 成功类：无/有 auth header、cookies array、header 两种大小写与 array/string、request shape、data return。
- 错误类：401、三类 GraphQL auth code、普通 500、普通 GraphQL error、空 data、网络 reject。
- 状态类：auth error 清 token/Workspace；非 auth error 保留 token；每 test module state 完全重置。
- 明确 defer 到 005：失败响应携带 cookie、session hydration rollback、按账号隔离通知/pending scene。

## Done criteria

- [ ] `vitest` 精确固定为 `4.1.10`，direct license MIT，严格许可证门禁通过。
- [ ] `pnpm exec vitest run tests/api-client.test.ts` exit 0，无 skipped/todo。
- [ ] `pnpm test:unit` exit 0，同时实际运行既有 Node tests 和新 API tests。
- [ ] `pnpm typecheck`、`pnpm check:licenses`、`git diff --check` exit 0。
- [ ] `git diff --exit-code -- miniprogram/src/api/client.ts miniprogram/src/api/real.ts miniprogram/src/state` exit 0。
- [ ] `rg -n "401|unauthorized|unauthenticated|not_authenticated|Set-Cookie|set-cookie|服务端未返回数据" miniprogram/tests/api-client.test.ts` 命中对应测试。
- [ ] 没有真实 endpoint、cookie、AppID 或 credential 写进 fixture/log。
- [ ] `advisor-plans/README.md` 的 004 状态已更新。

## STOP conditions

立即停止并报告，如果：

- 001 未 DONE，或新增 Vitest 传递树被严格许可证门禁拒绝。
- registry 中 `vitest@4.1.10` 不再显示 MIT，或安装会升级无关 Taro/React/TypeScript major。
- 必须修改 `src/api/client.ts` 才能让 characterization tests 通过；记录失败合同交给 005。
- Taro mock 需要 jsdom、真实开发者工具或真实 credential。
- Node tests 与 Vitest 无法在同一 `test:unit` 入口顺序执行，且解决需要移植所有既有测试。
- 任一步验证在一次合理修正后仍失败，或需要触碰 Scope 外文件。

## Maintenance notes

- 所有新增 API failure contract 应优先放在该文件并复用同一 Taro mock，避免每页各造 transport mock。
- reviewer 重点检查 module reset 是否真的隔离 `authToken`，以及非 auth failure 没被错误清会话。
- 005 会在这套基线上加入“失败响应不得提交 cookie”和账号隔离测试；不要提前锁定当前坏行为。
