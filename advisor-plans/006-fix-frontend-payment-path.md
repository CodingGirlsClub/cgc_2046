# Plan 006: 修复前端收费报名链路——payment_pending 解析崩溃与裁剪端支付页跳转

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- miniprogram/src/domain/format.ts miniprogram/src/pages/register-form/index.tsx miniprogram/src/domain/payment.ts miniprogram/package.json miniprogram/tests/payment-domain.test.ts`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

后端缴费闭环（ADR-0007、payment plan U1-U14）已把收费报名做成 v1 路径：付费报名提交后
服务端返回 `payment_pending` 状态的 Enrollment。但小程序前端的状态解析白名单没有这个
值——**付费用户提交报名后前端直接抛「服务端返回未知报名状态」，表单显示提交失败，而
服务端其实已创建占位报名**；「我的报名」列表页同样崩。第二处：表单页跳支付页没有平台
守卫，抖音/小红书（裁剪端）构建里根本没有支付页，跳转必然失败、用户卡死。两处都是
钱路径上的 S 级两行修复 + 测试钉死。

## Current state

- `miniprogram/src/domain/format.ts` — 领域枚举 fail-closed 解析器。第 62-65 行：

```ts
export function parseEnrollmentStatus(value: string): EnrollmentStatus {
  if (value === 'pending' || value === 'confirmed' || value === 'rejected' || value === 'expired' || value === 'cancelled') return value
  throw new Error(`服务端返回未知报名状态：${value}`)
}
```

  类型 `EnrollmentStatus`（`miniprogram/src/domain/models.ts:4`）**已包含** `payment_pending`，
  词表 `miniprogram/src/domain/payment.ts:173` 与 mock（`miniprogram/src/api/mockTransport.ts:161`）
  也都假设该状态存在——只有这个解析器漏了。

- 调用方（解析失败即抛错的链路）：
  - `miniprogram/src/api/real.ts:251`（createEnrollment 响应解析）与 `:295`
    （getEnrollments 列表解析）都调用 `parseEnrollmentStatus`。
  - `miniprogram/src/pages/register-form/index.tsx:66-78`：

```tsx
      const enrollment = await api.createEnrollment({ ... })
      Taro.setStorageSync(STORAGE_KEYS.lastEnrollment, enrollment)
      if (enrollment.status === 'payment_pending') {
        // 收费报名：占位完成即进支付页(R5：2h 限时窗)
        await Taro.redirectTo({ url: `/pages/order-pay/index?enrollmentId=${enrollment.id}` })
        return
      }
      await Taro.redirectTo({ url: `/pages/enrollment-result/index?id=${enrollment.id}` })
```

  注意：`redirectTo` 到 order-pay 是**无条件**的。而 `miniprogram/src/app.config.ts` 中
  order-pay 只在 `fullPages`（weapp）里，裁剪端 `cutPages`（tt/xhs）没有该页。
  同一入口在 `miniprogram/src/pages/my-enrollments/index.tsx:132-142` 已有正确守卫先例
  （`process.env.TARO_ENV === 'weapp'` 才显示「去支付」，否则引导网页端）——本计划沿用
  该约定。

- 平台判定约定：`process.env.TARO_ENV`（编译期常量），先例见
  `my-enrollments/index.tsx:132`、`app.config.ts:1`。裁剪端付费报名的产品语义 =
  占位成功 + 引导到网页端支付（my-enrollments 已定文案先例），**不是**在小程序内支付。

- 测试基建：`miniprogram/package.json` 的 `test:unit` 脚本是**显式文件清单**：

```
"test:unit": "node --experimental-strip-types --test tests/domain.test.ts tests/payment-domain.test.ts tests/diversion-policy.test.ts tests/license-policy.test.mjs && vitest run tests/api-client.test.ts tests/account-state.test.ts tests/real-auth.test.ts"
```

  新增测试文件必须同时加进这个清单（node --test 部分跑纯 TS 纯函数，
  vitest 部分跑带 mock 的模块测试）。`tests/payment-domain.test.ts` 是
  node --test 清单里的支付纯函数测试，本计划的纯函数测试放这里。

## Commands you will need

| Purpose | Command (cwd = `miniprogram/`) | Expected on success |
|---------|-------------------------------|---------------------|
| Typecheck | `pnpm typecheck` | exit 0 |
| Unit tests | `pnpm test:unit` | 全部 pass（含新增用例） |
| License gate | `pnpm check:licenses` | exit 0（无新依赖时不变） |

## Scope

**In scope** (the only files you should modify):
- `miniprogram/src/domain/format.ts`
- `miniprogram/src/domain/payment.ts`
- `miniprogram/src/pages/register-form/index.tsx`
- `miniprogram/tests/payment-domain.test.ts`
- `miniprogram/package.json`（仅当新建测试文件需要加清单时；优先不新建文件，见 Step 3）

**Out of scope** (do NOT touch):
- `miniprogram/src/pages/order-pay/**`、`my-enrollments/**` —— 支付页与既有守卫先例，不动。
- `miniprogram/src/api/real.ts`、`mockTransport.ts`、`operations.ts` —— 解析修复不需要动数据层。
- 后端任何文件；order-pay 页注册进 cutPages（裁剪端不做小程序内支付，是既定产品红线，
  见 advisor-plans/README.md「Findings considered and rejected」与 DOUYIN_REDNOTE_CHECKLIST）。

## Git workflow

- Branch: `advisor/006-frontend-payment-path`
- Commit style（仓库先例 `git log --oneline`）：
  `fix(miniprogram): parseEnrollmentStatus 补 payment_pending + 裁剪端支付跳转守卫 (#NNN)`
  分两步提交亦可（每步一个可验证修复）。
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: parseEnrollmentStatus 补 payment_pending

`miniprogram/src/domain/format.ts` 白名单加入 `'payment_pending'`（放在 `'pending'` 旁边，
保持与 `parseOrderStatus` 词表一致）。

**Verify**: `cd miniprogram && pnpm typecheck` → exit 0

### Step 2: 支付落地页纯函数 + 平台守卫

在 `miniprogram/src/domain/payment.ts` 新增纯函数（返回跳转 URL，不执行跳转，便于测试）：

```ts
// 收费报名提交后的落地页：weapp 进支付页；裁剪端（tt/xhs）无小程序内支付，
// 回结果页（结果页已渲染 payment_pending 状态与网页端支付引导文案）。
export function paymentLandingUrl(
  enrollmentId: string,
  isWeapp: boolean
): string {
  if (isWeapp) return `/pages/order-pay/index?enrollmentId=${enrollmentId}`
  return `/pages/enrollment-result/index?id=${enrollmentId}`
}
```

`miniprogram/src/pages/register-form/index.tsx` 的 `payment_pending` 分支改为：

```tsx
      if (enrollment.status === 'payment_pending') {
        // 收费报名：weapp 占位完成即进支付页(R5：2h 限时窗)；
        // 裁剪端无小程序内支付，回结果页引导网页端支付（同 my-enrollments 守卫语义）。
        await Taro.redirectTo({
          url: paymentLandingUrl(enrollment.id, process.env.TARO_ENV === 'weapp')
        })
        return
      }
```

（import `paymentLandingUrl` from `'@/domain/payment'`，对齐文件内既有 import 风格。）

**Verify**: `cd miniprogram && pnpm typecheck` → exit 0

### Step 3: 测试钉死

在 `miniprogram/tests/payment-domain.test.ts`（node:test 风格，文件内已有
`import { test } from 'node:test'` 的先例，模仿同文件现有用例结构）新增两组：

1. `parseEnrollmentStatus('payment_pending')` 返回 `'payment_pending'` 不抛错
   （import 自 `../src/domain/format.ts`，对齐该文件现有 import 路径写法）。
2. `paymentLandingUrl`：weapp → `/pages/order-pay/index?enrollmentId=...`；
   非 weapp → `/pages/enrollment-result/index?id=...`。

**Verify**: `cd miniprogram && pnpm test:unit` → 全绿，含 ≥4 个新断言

## Test plan

- 新用例：payment_pending 解析（回归钉）、paymentLandingUrl 双分支。
- 结构先例：`tests/payment-domain.test.ts` 内现有 `test(...)` 块。
- 回归：`pnpm test:unit` 全量通过（该脚本覆盖 domain/payment-domain/diversion/license/api-client/account-state/real-auth）。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd miniprogram && pnpm typecheck` exit 0
- [ ] `cd miniprogram && pnpm test:unit` exit 0，且包含 payment_pending 解析与
      paymentLandingUrl 用例
- [ ] `grep -n "payment_pending" miniprogram/src/domain/format.ts` 命中白名单行
- [ ] `grep -n "order-pay" miniprogram/src/pages/register-form/index.tsx` 只出现在
      paymentLandingUrl 调用路径（不再有无守卫的裸 redirectTo）
- [ ] `git status` 无 in-scope 之外的改动
- [ ] `advisor-plans/README.md` 状态行已更新

## STOP conditions

Stop and report back (do not improvise) if:

- format.ts / register-form 现状与「Current state」摘录不符（代码已漂移）。
- `EnrollmentStatus` 类型（models.ts）里没有 `payment_pending`（说明前端契约另有一套，先报告）。
- payment plan 文档（docs/plans/2026-08-15-024）或 my-enrollments 现行文案表明裁剪端
  付费报名的落地语义已改为其他设计（本计划的「回结果页」是沿用现有守卫先例的推断）。
- typecheck/test 因与本改动无关的既有错误失败（报告原始输出）。

## Maintenance notes

- 若后续 U12 验收给裁剪端增加「网页端支付」深链，`paymentLandingUrl` 是唯一改动点。
- 复审重点：register-form 的 catch 分支文案在 payment_pending 已创建占位的情况下是否
  仍可能误导（本次不动文案；解析修复后该分支只在真失败时触达）。
- 本计划不处理后端 CORR-03（通知/小程序码落页）——见 plan 008。
