# 小程序（Taro 4 + React 18）

微信小程序全量端 + 裁剪端（tt / xhs，页面表见 `src/app.config.ts`）。

## 验证命令

`pnpm <script>` 在本机可能先撞 pnpm 的依赖状态检查（`ERR_PNPM_IGNORED_BUILDS`）而整条失败；直接调仓内二进制最稳：

| 目的 | 命令 |
| --- | --- |
| 类型 | `./node_modules/.bin/tsc --noEmit` |
| 单测 · 纯逻辑（node --test） | `node --experimental-strip-types --test tests/payment-domain.test.ts …` |
| 单测 · transport 层（vitest） | `./node_modules/.bin/vitest run tests/api-client.test.ts …` |
| 构建 | `./node_modules/.bin/taro build --type weapp｜tt｜xhs` |
| 依赖许可 / 零导流 | `node scripts/check-licenses.mjs` / `node scripts/check-no-diversion.mjs`（导流检查需先建出 `dist/tt`、`dist/xhs`） |
| CI 全量门 | `pnpm check:ci`（codegen 新鲜度 + typecheck + 许可 + 单测 + 三端构建 + 零导流 + mock 构建） |

- `pnpm install` 会往 `pnpm-workspace.yaml` 写 `allowBuilds` 占位行（`'@tarojs/binding': set this to true or false`）——那是 install 噪音，提交前 `git checkout -- pnpm-workspace.yaml`。
- `dist/` 不入库（`miniprogram/.gitignore`）；提交永远只含 `src/`、`tests/`、`e2e/`、配置。

## GraphQL 契约层

- 文档单源 = `src/api/operations.ts`；`src/api/generated/{schema,graphql}.ts` 是 **codegen 产物，必须随文档一起提交**（`check:ci` 跑 `pnpm codegen && git diff --exit-code -- src/api/generated`）。
- SDL 取本地文件 `../backend/priv/graphql/schema.graphql`，**不需要后端在跑**；改完文档执行 `./node_modules/.bin/graphql-codegen-cjs --config codegen.yml`。
- 新增字段前先确认后端 attribute 是 `public?: true`（SDL 里非空才算可用）；否则要先改后端再 codegen。

## 页面逻辑一律下沉 domain

小程序**没有页面渲染测试**（无 `@tarojs/test-utils` / jsdom 面）。因此页面里的判据、文案、状态机必须抽成 `src/domain/*.ts` 的纯函数，用 `node --test` 钉住；页面只留渲染与调起（样板：`domain/payment.ts` 的 `canRequestPayment` / `paymentBlockCopy`）。

## E2E（只覆盖小程序；web 端走 ego-browser）

E2E 跑在**微信开发者工具模拟器**里，与 web 的 ego-browser 无关，也**不进 CI**（需要 GUI 与人工授权，`check:ci` 不含 e2e）。

| 入口 | 依赖 | 覆盖 |
| --- | --- | --- |
| `pnpm e2e`（`e2e/journey.e2e.mjs`） | miniprogram-automator + DevTools CLI | 全链旅程回归；锚点表 `e2e/anchors.mjs`，CI 侧 `node scripts/check-anchors.mjs` 构建后静态自检 |
| `pnpm e2e:order-pay-consent` | wechatide CLI + 已登录的 DevTools | 押金同意门（创单前勾选 → 带 consent 创单 → 支付），带截图 |
| `pnpm e2e:initiative` | 同上 | 倡导活动旅程、详情页回链 / 成班徽章，带截图 |
| `pnpm e2e:flashback` | 同上 | 「我的闪念间」主旅程，带截图 |
| `e2e/` 下其余 `*.e2e.py` / `*.e2e.mjs` | 同上 | 闪念间与许愿树的子旅程；未登记为 pnpm 脚本，直接 `python3` / `node` 跑，前置条件见各脚本头注释 |

跑 e2e 的四条纪律：

1. **前置**：小程序依赖——**新 worktree 跑一次 `bash scripts/worktree/setup-worktree.sh` 即会装好**；没跑过该脚本的 worktree 需自己跑一次 `cd miniprogram && pnpm install --frozen-lockfile`（缺依赖时脚本会预检报错并直说，不会伪装成「mock 构建失败」）。另需 wechatide-skill 装在 `.agents/skills/wechatide-skill`；首次调用 `wechatide` 会在工具内弹授权窗，需人工点同意（client 名用 `CGC_WECHATIDE_CLIENT` 覆盖；shell 脚本默认 `DSH`，py 脚本默认 `Codex`）。工具没登录 → 先扫码。
2. **选择器只用 CSS-module 类名**（`data-testid` 是惰性属性，见 #579）。类名哈希随样式变，运行时解析、别写死：journey 走 `e2e/anchors.mjs`（锚点表单源，页面类从 `dist/weapp/<page>/index.wxss`、组件类从 `dist/weapp/common.wxss` 解析），shell 版参考 `e2e/order-pay-deposit-consent.e2e.sh` 的 `cls()`（页面类）与 `e2e/flashback-journey.e2e.sh` 的 `clsCommon()`（组件类，多哈希 = 跨组件同名 → 报错换锚）。
3. **`--wait-for-selector` 是「执行前等待」**（`automation_navigate` / `automation_element_action` 都是）。用它等**本步要操作的元素**；当成「导航后等新页面」用会卡在等一个还不存在的元素上，页面根本不跳。
4. **e2e 走 mock transport**（`CGC_E2E_MOCK=true` 构建；`pnpm e2e` 与 shell 脚本会自己构建）。打**真实后端**的例外：`flashback-guest.e2e.py`，以及 `voices-cities.mjs` / `voices-layout.mjs`（两者打 `127.0.0.1:4107` 的 GraphQL，需先按各自头注释 seed `e2e/fixtures/voices-cities.exs` / `voices-layout.exs`）。样例与流转逻辑在 `src/api/mockTransport.ts`：加字段/加页面要同步改它，否则 `parseOrderKind` 这类 fail-closed 解析会直接把页面打成错误态，e2e 红得莫名其妙。

## 资金动作门（押金同意）不变量

押金单必须明示「押金 ¥xx（到场退）+ 未到场不退」并取得显式勾选同意（与 web 收银框 U1 / /orders/new 同源）。**两道门，判据不得混用**：

1. **创单前门**（`preCreateDepositGate`，`src/pages/order-pay/index.tsx`）：押金场先「勾选」→ `createOrder(enrollmentId, true)`（带 `depositConsent`）→ 支付。判据 = **报名快照** `Enrollment.paymentMode === 'deposit'` + `depositAmountCents`（两者都以**活动现值**为权威——后端计算字段与创单金额同源同值，预检走 `api.getEnrollment`）。后端按 `order_kind` 权威复核：押金单缺 `depositConsent: true` → `order_deposit_consent_required` 拒单，页面经 `createOrderSelfHealsToConsent`（#751）识别后转「披露 + 勾选」流程自愈，不落同构重试死循环。
2. **支付前门**（`canRequestPayment`）：押金单未勾选不放行 `Taro.requestPayment`（纵深防御）。判据 = **订单自己的口径快照** `Order.orderKind === 'deposit'` + `order.amountCents`（订单创建后不随活动配置漂移）。

- **不要**用活动的实时缴费配置（`offering.depositEnabled` / `CatalogItem.depositAmountCents`）当钱动前的判据——活动随时可改配置，订单创建后用户同意的是这一笔。创单前那一格是唯一例外（订单还不存在），判据取 `Enrollment.paymentMode`/`depositAmountCents`（与创单实付同源）；创单后一律切到订单快照。
- **金额语义（#749）**：创单实付与披露金额都以活动现值为权威，`submission_payload` 不参与金额（历史预埋脏键天然免疫）。组织者改押金额后，未支付报名的披露与创单同步跟随新价；只有**已创建订单**的金额钉死在 `tier_snapshot`。旧口径「报名时物化快照、改价不追溯」已废弃，不要再按它写断言或文案。
- 新增任何资金动作入口都要挂同一道门，并扫查 `Taro.requestPayment` 与 `api.createOrder` 的调用点（当前各一处，均在 `src/pages/order-pay/index.tsx`）。
- `src/api/mockTransport.ts` 必须镜像后端门（押金场缺 `depositConsent` → 同 code 业务错误），否则 e2e 会在 mock 上「绿着漏门」。

## 后端先收紧 × 旧版小程序（#751）

后端门是权威、fail-closed：后端收紧先于小程序过审上线时，旧版小程序的对应请求会被硬拒（如押金创单缺 `depositConsent: true` → `order_deposit_consent_required`）。这是设计而非故障——客户端版本只决定它自己是否被拒，绝不削弱门，所以**不要为旧版在后端放宽门**。

- 旧版被拒后落业务错误态，`src/domain/error-copy.ts` 的文案已含「若小程序为旧版本，请更新后重试」引导；新版的自愈见上节 `createOrderSelfHealsToConsent`。
- 发版顺序（客户端先过审、后端再收紧）见根 `AGENTS.md`「PR 合并与发布」；code ↔ 文案的同步链见 `backend/AGENTS.md`「错误码契约」。
