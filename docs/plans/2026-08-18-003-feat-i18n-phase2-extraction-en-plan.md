---
title: i18n Phase 2+3 — 存量抽取 + en 初稿 - Plan
type: feat
date: 2026-08-18
topic: i18n-phase2-extraction-en-draft
execution: code
sop: medium-tier（单 worktree、单 writer、多逻辑 commit、一个 PR 收口；用户拍板"全部做完再提 PR"）
parent-roadmap: i18n 路线（Phase 0 = PR #227；Phase 1 = PR #235）
---

# i18n Phase 2+3 — 存量抽取 + en 初稿（轨道 003）

## Objective

web 端全部存量中文 UI 字符串迁入 `zh-CN.json`（source of truth），全站 `next/link` 换 next-intl navigation；`en.json` 填满 AI 初稿（翻译基准：zh-CN source + 术语表）；hreflang/alternates 就位。完成后 `/en` 全站英文可见（初稿质量），zh-CN 渲染与现状逐字节一致。**单 PR 收口**（用户拍板）。

## Out of scope

- Phase 4 DB 内容双语（translations 子表 + GraphQL locale 参数）——既定决策数据驱动启动，不做
- en 人工复审与本地化 UX 审查（PR 合并后独立迭代；AI 初稿即用户可见，用户已拍板）
- 小程序端（纯中文平台，排除）
- 后端 Gettext/邮件多语言
- miniprogram order-pay `/cancel/i`、invite-batch-panel 正则（范围外维持）

## Current-state evidence（2026-08-18，Phase 1 合并后）

- Phase 1 已就位：`[locale]` 路由、切换器、协商链、`check:i18n` key 检查（22 键）、messages 骨架
- 中文硬编码分布：**130 源文件**（app/[locale] 页面 + components + lib 错误文案）、**86 测试文件**（断言中文 UI 串）、**44 文件用 `next/link`**
- 现有 `web/test-utils.tsx` 可扩展为统一 provider wrapper
- Phase 1 遗留记档：`check:i18n` 已挂 `pnpm test` 前置（key 集合相等门禁自动生效）

## Design

### D1 抽取原则

- **key 风格**：semantic key（`auth.login.submit` / `orders.duplicateActivePending` 形态，domain.camelCase；`errors.*` 沿用错误码 key 已有形态）
- **zh-CN 为 source**：原文照迁，不改写；一条不落（`check:i18n` 只比对集合相等，覆盖率靠验收脚本）
- **测试策略（最大工程风险，86 文件）**：`test-utils.tsx` 统一提供 zh-CN `NextIntlClientProvider` wrapper；**测试断言文案不变**（zh-CN source 决定），仅 render 调用包 wrapper / mock 层适配——测试改动是结构性 wrapper 注入，非逐断言重写
- **lib 层错误文案**（非组件内）：迁入 messages 对应 namespace，经 hook/context 取用（payment-errors.ts 已有 `usePaymentErrorTranslator` 模式，同款推广）

### D2 分批 commit（单 PR 内，按域串行）

| 批 | 域 | 涉及面（估） |
|---|---|---|
| B1 | test-utils provider 基建 + 全局 mock 适配 | 1 + 86 测试文件 wrapper 注入 |
| B2 | (auth) 家族：login/register/forgot/reset + auth-shell | ~8 源文件 |
| B3 | landing + 公开页（courses/events/join/apply） | ~10 |
| B4 | workspace 家族（shell/nav/members/permissions/profile/settings） | ~15 |
| B5 | payments/orders/participations/offering 家族 | ~12 |
| B6 | admin 家族（7 页 + guard） | ~10 |
| B7 | learning/其它组件 + lib 文案收尾 | ~20 |
| B8 | `next/link` → `@/i18n/navigation` 全量替换（44 文件，as-needed 下行为不变） | 44 |
| B9 | en 初稿（术语表 → 全量翻译）+ hreflang alternates + metadata | messages + layout |

每批：抽取 → zh-CN.json 增量 → 测试过 → commit。B1 先行立稳测试基建，后续批次才能不逐个修测试。

### D3 en 初稿 + 术语表

- **术语表先行**：`docs/i18n/术语表.md`——CONTEXT.md 核心领域术语英译（Workspace/Enrollment/Offering/Sponsorship/StepRole 等既定英文词），翻译唯一基准；产品专名（CGC 2046/OpenClacky）不译
- en 翻译范围 = zh-CN.json 全量 key；语气：简洁专业，非直译；按钮/CTA 用动词短语
- **hreflang**：`[locale]/layout.tsx` `alternates.languages`（zh-CN 无前缀 / en 前缀 canonical）
- metadata title/description 双语（Phase 1 已有结构，填值）

### D4 验收脚本（防漏抽）

- `scripts/check-i18n-coverage.mjs`（或并入 check:i18n）：grep 源文件残留中文串（白名单：注释、testid、正则、class、console、URL、纯数据 mock）→ 非白名单残留即 fail
- 抽查方式：逐批人工 spot-check + 脚本兜底

## Tests

- B1：wrapper 后全量测试基线绿（685 基线）
- 每批：该域测试 + 全量回归绿
- en 侧：抽样冒烟（`/en` 渲染若干页断言英文串出现）+ `check:i18n` 集合相等
- 最终：`pnpm build`（45+ 路由两 locale 静态检查）+ agent-browser 冒烟（`/` 逐字节一致 + `/en` 若干页英文 + 切换回归）

## Verification

- `cd web && pnpm typecheck && pnpm lint && pnpm test && pnpm build && pnpm check:i18n`
- backend/miniprogram 不涉改动（跑回归确认无意外）
- agent-browser：`/` 与 develop 逐字节一致（signoff 硬标准）；`/en/login`、`/en` landing、workspace 一页英文渲染；语言切换（含 query 保留）

## Rollback

- 纯 web 改动，无 DB/契约变更；PR 粒度 revert 即回
- 风险点：B1 测试基建若与某些测试的既有 mock 冲突，逐文件兼容（wrapper 可选注入）

## Signoff criteria

1. `check-i18n-coverage` 0 残留（白名单外）
2. zh-CN 渲染与 develop 逐字节一致（抽查 5+ 页）
3. en 全量 key 覆盖（check:i18n 绿）+ 抽样页英文渲染
4. hreflang/metadata 双语就位
5. 全量测试绿 + build 绿

## Human decisions required

1. **en 初稿随本 PR 对用户可见**（AI 翻译、未经人工复审）——已按你"做完所有 phase 再提 PR"的指令默认接受，此处显式确认
2. 单 PR 体量大（~150 文件、9 逻辑 commit）：评审负担重但历史清晰（git mv 语义、按域分批）；若要拆 PR 与你指令冲突，默认不拆
