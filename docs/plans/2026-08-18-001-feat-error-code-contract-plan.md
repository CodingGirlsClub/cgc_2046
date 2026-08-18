---
title: Error Code Contract - Plan
type: feat
date: 2026-08-18
topic: error-code-contract
execution: code
sop: medium-tier（写计划 → 人工批准 → sole-writer 实施 → 独立评审 → 验证）
---

# Error Code Contract - Plan（i18n 路线 Phase 0）

## Objective

GraphQL mutation errors 携带**稳定业务 code**（`<resource>_<reason>` snake_case），web 与小程序按 code 渲染本地文案，**删除前端对英文 message 的正则匹配**。独立价值：修掉 `translatePaymentError` 的脆弱字符串匹配、小程序英文报错直出 toast 的体验问题；同时是国际化路线的前置（前端 code→文案表将来直接替换为 locale 消息文件，后端一行不改）。

## Out of scope

- Ash class code（`invalid_attribute` / `not_found` / `forbidden` 等）不动——业务 code 只加在 domain 层主动构造的错误上
- 非 payment/enrollment 主链路的英文 message（如 `workspace.ex` join_policy 三条）不转；后续按页面 i18n 时逐页收编
- Gettext 启用、next-intl 接入、DB translations（i18n Phase 1+）
- 后端错误 message 本身仍是英文（作为 code 的人读 fallback 与日志语料保留）

## Current-state evidence

- **错误产生模式统一**：6 个 domain 文件用 `add_domain_error(changeset, reason_atom)` + `domain_error_message/1` 私有函数——reason 原子天然就是错误码，现状在转英文 prose 时丢弃：
  - `backend/lib/cgc_2046/events/enrollment.ex:958-983`（prefix 将为 `enrollment_`）
  - `backend/lib/cgc_2046/payments/order.ex:1011-1026`（`order_`）
  - `backend/lib/cgc_2046/events/speaker_invitation.ex:830-854`（`speaker_invitation_`）
  - `backend/lib/cgc_2046/events/sponsorship.ex:871-896`（`sponsorship_`）
  - `backend/lib/cgc_2046/events/sponsorship_delivery.ex:136-145`（`sponsorship_delivery_`）
  - `backend/lib/cgc_2046/accounts/membership_context.ex:504-515`（`membership_`）
- **项目内已有该模式的验证先例**：`backend/lib/cgc_2046/accounts/platform_admin_error.ex` —— `use Splode.Error, fields: [:message, :code], class: :invalid` + `defimpl AshGraphql.Error`（本 plan 照抄此模板，不发明新东西）
- **ash_graphql 错误结构已带 code**：`deps/ash_graphql/lib/error.ex` 的 `to_error/1` 协议返回 `%{message, short_message, vars, code, fields}`；mutation error SDL 已含 `code` 字段（SDL 不变）
- **手写 resolver 已有 inline code 先例**：`graphql_schema.ex` 的 `registration_failed` / `rate_limited` / `invalid_reset_token`
- **web 端 9/13 个 GraphQL document 已 select `code`**；未 select 的是 `events.ts`（11 处）、`orders.ts`（4）、`sponsorship.ts`（4）、`approvals.ts`（2）
- **正则匹配层**：`web/lib/payment-errors.ts` KNOWN 表 13 条正则匹配英文句子；5 个组件消费
- **前端已有对业务 code 的期待但后端从未兑现**：`web/app/participations/page.tsx:362` 判 `error.code === "already_processed"`，实际靠 `error.message?.includes("already processed")` 兜底——裸名跨资源歧义（enrollment/order/sponsorship 三处 `already_processed` 语义与文案不同），本 plan 定名资源前缀，此处同步改
- **小程序现状**：`miniprogram/src/api/real.ts:118` `mutationError` 直接把英文 message join 进 toast；约 15 处页面 `reason.message` 直出
- **唯一约束路径**：`createEnrollment` 撞唯一索引产生 Ecto "has already been taken"（web 正则第 1 条）；判法先例 `MembershipContext.unique_membership_conflict?/1`（`constraint_type: :unique`）

## Design

### 后端

1. 新增 `backend/lib/cgc_2046/errors/business_error.ex`：

   ```elixir
   defmodule Cgc2046.Errors.BusinessError do
     use Splode.Error, fields: [:message, :code, :fields], class: :invalid
     def message(error), do: error.message
   end

   defimpl AshGraphql.Error, for: Cgc2046.Errors.BusinessError do
     def to_error(error) do
       %{message: error.message, short_message: error.message,
         code: error.code, vars: %{}, fields: List.wrap(error.fields || [])}
     end
   end
   ```

   - `vars: %{}` 必须给（`AshGraphql.DefaultErrorHandler` 对 message 做 `%{var}` replace）
   - 模板：`platform_admin_error.ex`（C664）

2. 六文件 `add_domain_error/2` 改为构造 `BusinessError`：
   - code = 资源前缀 + reason：`"enrollment_already_processed"`、`"order_provider_not_configured"` 等
   - `domain_error_message/1` 保留为英文 message 来源（现有调用点语义不变）
   - `{:database, _}` 统一 code `"database_error"`（500 类故障，非业务分支）
   - 检查并消除跨文件同名歧义：`:target_tenant_mismatch` 三处语义一致（"target does not belong to tenant"），加资源前缀后自然消歧

3. `order.ex` 给 `:provider_not_configured` 加显式子句（现走 `inspect(reason)` 兜底裸原子）。

4. `enrollment.ex` `createEnrollment` 捕获唯一约束冲突转 `BusinessError`（code `enrollment_duplicate_active`；按 `unique_membership_conflict?/1` 同款 `constraint_type: :unique` 判法）。

### web

5. `payment-errors.ts` 重写：`Record<string, string>` code→中文文案（13 条从现有 KNOWN 表迁移），`translatePaymentError(code, fallback)` 精确查表；**正则数组删除**（同仓同步部署，无版本漂移，不留兼容层）。
6. 组件调用点改传 `payload?.errors[0]?.code`：`offering-pages.tsx`、`public-offering-detail.tsx`、`payment-checkout-dialog.tsx`、`payments-management.tsx`、`app/orders/[id]/page.tsx`、`app/orders/new/page.tsx`。
7. documents 补 `code` selection：`events.ts` / `orders.ts` / `sponsorship.ts` / `approvals.ts`。
8. `participations/page.tsx:362`：`code === "already_processed"` → `"enrollment_already_processed"`，删 message 正则兜底。

### miniprogram

9. `src/api/operations.ts` 相关 document 补 `code`；`pnpm codegen` 再生成。
10. 新增 `src/domain/error-copy.ts`：code→中文表（与 web 同文案，注释互指；将来 i18n Phase 1+ 两端各自换 locale 消息文件）。
11. 订单/报名链路错误展示走 code：`order-pay`、`register-form`、`enrollment-result` 页面。`real.ts` `mutationError` 保持（通用兜底，拿不到 code 的场景用）。

## Tests（先于实施任务定案）

- backend 新增 `test/cgc_2046_web/graphql/error_code_contract_test.exs`（沿用 API contract test 惯例，advisor-plans 004）：
  - `createEnrollment` 重复活跃报名 → `errors[0].code == "enrollment_duplicate_active"`
  - `createOrder` 已处理 → `"order_already_processed"`
  - sponsorship 审批冲突 → `"sponsorship_already_processed"`
  - 断言所有业务 code 匹配 `~r/^[a-z]+(_[a-z0-9]+)+$/`（命名规范钉测）
- web `payment-errors.test.ts`：改 code 精确匹配用例 + 未知 code/null → fallback
- miniprogram `tests/` 新增 error-copy 映射用例（每个 code 有非空文案）

## Verification

- `cd backend && mix precommit`
- `cd web && pnpm typecheck && pnpm test`
- `cd miniprogram && pnpm check:ci`
- 端到端冒烟：dev 环境 duplicate enrollment / already-processed order 场景，web 与小程序均显示中文人话而非英文原文

## Phases

| Phase | 内容 | 产出 |
|---|---|---|
| P1 | 后端 BusinessError + 六文件改造 + unique 捕获 + contract tests | backend 全绿 |
| P2 | web selection 补齐 + payment-errors 重写 + 调用点 + 测试 | web 全绿 |
| P3 | miniprogram selection + codegen + error-copy + 测试 | 小程序全绿 |

三 Phase 各自独立 commit，顺序执行（P2/P3 依赖 P1 的 code 值）。

## Rollback

- 无 DB 迁移、无 GraphQL SDL 变更、无配置变更；每 Phase 单 commit，`git revert` 即回
- 风险点：AshGraphql.Error 协议实现细节——模板已在项目内验证（PlatformAdminError 生产在用），残余风险低

## Signoff criteria

1. contract test 全绿，code 命名符合 `<resource>_<reason>` 规范
2. web/小程序端到端：重复报名、订单已处理两场景显示中文文案
3. `payment-errors.ts` 正则数组删除，全库无英文 message 正则匹配残留
4. 三端套件全绿

## Human decisions required

无阻塞决策。中文文案沿用 `payment-errors.ts` KNOWN 表现值，无新增文案决策点。批准本 plan 即可进入实施。
