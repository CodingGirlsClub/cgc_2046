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

| 脚本 | 依赖 | 状态 |
| --- | --- | --- |
| `e2e/journey.e2e.mjs`（`pnpm e2e`） | miniprogram-automator + DevTools CLI | 可用（#579 已修）：全链旅程回归（13 断言·分组计数）；锚点表 `e2e/anchors.mjs`，CI 侧 `node scripts/check-anchors.mjs` 构建后静态自检 |
| `e2e/order-pay-deposit-consent.e2e.sh`（`pnpm e2e:order-pay-consent`） | wechatide CLI + 已登录的 DevTools | 可用；押金同意门回归（11 断言 + 截图） |
| `e2e/initiative-journey.e2e.sh`（`pnpm e2e:initiative`） | wechatide CLI + 已登录的 DevTools | 可用；倡导活动旅程 + 详情页回链/成班徽章回归（16 断言 + 截图） |

跑 e2e 的四条纪律：

1. **前置**：小程序依赖——**Paseo 建的 worktree 由 `paseo.json` 的 setup 自动装好**；手工 `git worktree add` 建的、或早于该 setup 的 worktree 需自己跑一次 `cd miniprogram && pnpm install --frozen-lockfile`（缺依赖时脚本会预检报错并直说，不会伪装成「mock 构建失败」）。另需 wechatide-skill 装在 `.agents/skills/wechatide-skill`；首次调用 `wechatide` 会在工具内弹授权窗，需人工点同意（client 名默认 `DSH`，用 `CGC_WECHATIDE_CLIENT` 覆盖）。工具没登录 → 先扫码。
2. **选择器只用 CSS-module 类名**（`data-testid` 是惰性属性，见 #579）。类名哈希随样式变，运行时解析、别写死：journey 走 `e2e/anchors.mjs`（锚点表单源，页面类从 `dist/weapp/<page>/index.wxss`、组件类从 `dist/weapp/common.wxss` 解析），shell 版参考 `e2e/order-pay-deposit-consent.e2e.sh` 的 `cls()`。
3. **`--wait-for-selector` 是「执行前等待」**（`automation_navigate` / `automation_element_action` 都是）。用它等**本步要操作的元素**；当成「导航后等新页面」用会卡在等一个还不存在的元素上，页面根本不跳。
4. **e2e 走 mock transport**（`CGC_E2E_MOCK=true` 构建）。样例与流转逻辑在 `src/api/mockTransport.ts`：加字段/加页面要同步改它，否则 `parseOrderKind` 这类 fail-closed 解析会直接把页面打成错误态，e2e 红得莫名其妙。

## 资金动作门（押金同意）不变量

押金单在「立即支付」前必须明示「押金 ¥xx（到场退）+ 未到场不退」并取得显式勾选同意（与 web 收银框 U1 同源）。

- **判据只认订单自己的口径快照**：`Order.orderKind === 'deposit'` + `order.amountCents`（报名时物化的押金快照）。**不要**用活动的实时缴费配置（`Enrollment.paymentMode` / `offering.depositEnabled`）——活动随时可改配置，这一笔不会，用户同意的是这一笔。
- 金额不得用活动现价：组织者改价后，实时配置与在途订单的扣款额会不一致（web 收银框现存此问题，见 #580，小程序不要跟进）。
- 新增任何资金动作入口都要挂同一道门，并扫查 `Taro.requestPayment` 的调用点（当前仅 `src/pages/order-pay/index.tsx` 一处）。
