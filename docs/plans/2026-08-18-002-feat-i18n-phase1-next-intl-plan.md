---
title: i18n Phase 1 — next-intl 骨架 + 语言切换 - Plan
type: feat
date: 2026-08-18
topic: i18n-phase1-next-intl
execution: code
sop: medium-tier（写计划 → 人工批准 → sole-writer 实施 → 独立评审 → 验证）
parent-roadmap: i18n 路线（对话定稿 2026-08-18；Phase 0 = PR #227 错误码契约已合并）
---

# i18n Phase 1 — next-intl 骨架 + 语言切换（轨道 002）

## Objective

web 端接入 next-intl，建立多语言基础设施：`[locale]` 路由段（`zh-CN` 无前缀 / `en` 带前缀）、语言切换 UI（公开页 + 设置页）、协商链（URL > 用户偏好 > cookie > Accept-Language > zh-CN）。Phase 1 结束时**用户可以在页面上切换语言**（zh-CN/en），全站仍显示中文（en 文件为空壳），存量字符串抽取留给 Phase 2。

## L0 决策（本 plan 锚定，含用户拍板项）

1. **Locale 集**：`zh-CN`（默认）+ `en`；BCP47 对外命名，Gettext 内部 `zh_CN`/`en`（转换函数单点，Phase 4 前不涉及）
2. **路由模式**：`app/[locale]/` 动态段 + `localePrefix: 'as-needed'`——默认 zh-CN **无前缀**（现有 URL 全部不变，零 301），`en` 走 `/en/...` 前缀
3. **Source of truth（用户拍板 2026-08-18）**：**中文**永远是产品语义的裁决语言；**英文**是 translation pivot（Phase 3 起新语言的参照基准）。新文案先落 zh-CN（source），en 跟进；**en 上线门槛 = 100% key 覆盖**（英文用户不见中文兜底），CI 强制比对两文件 key 集合相等（Phase 1 建检查，仅 zh-CN 一份时自动通过）
4. **Key 风格**：semantic key（`orders.duplicateActivePending` 形态，domain.camelCase），禁止用原文（中或英）做 key——key 与 source 语言解耦，改文案不改 key
5. **协商优先级**：URL 路径 > User.locale（登录态）> cookie（`cgc_locale`）> `Accept-Language` > zh-CN；切换语言 = 写 cookie +（登录时）更新 User.locale + 导航到对应 locale 前缀 URL
6. **范围边界**：只做 web 端骨架与切换；Phase 2 存量抽取、Phase 3 en 翻译、Phase 4 DB 内容双语（启动时机数据驱动）不在本 plan

## Current-state evidence

- **Next 16.3 无 middleware.ts，用 `proxy.ts`**（Next 16 更名）；`web/proxy.ts` 已存在，承载 CSP nonce + security headers（matcher 排除 api/_next/static 等）——next-intl middleware 与之**同文件组合**，非新建
- **next-intl 4.0 完全兼容 Next 16 / proxy.ts**（官方文档 + 社区验证；`createMiddleware` from `next-intl/middleware` 在 proxy 中调用，`proxy.ts was called middleware.ts up until Next.js 16`）
- `web/app/layout.tsx`：`<html lang="zh-CN">` 硬编码；Inter（latin）+ Geist Mono 字体已加载——en 无需新字体
- **User 资源无 locale 字段**（`backend/lib/cgc_2046/accounts/user.ex` attributes：email/hashed_password/phone/is_platform_admin/display_name，无 locale）——跨设备持久化需后端小改
- **GraphQL 错误码契约已就位**（PR #227，921eb08）：`errors[0].code` 稳定业务 code，`web/lib/payment-errors.ts` code→中文表 15 键——Phase 2 抽取时该表直接并入 zh-CN.json 的 `errors` namespace，key 沿用 code 值
- **切换 UI 落点**：公开页（landing/auth 壳，匿名可切换）+ `web/app/settings/account/profile/page.tsx`（登录用户持久化）+ WorkspaceShell 无需改动（`SETTINGS_NAV` 注册表机制已收敛导航）
- 全站字符串硬编码中文（~35 组件，600–1000 条，Phase 2 处理，本 plan 不动存量）
- web AGENTS.md：新 npm 依赖须过 license gate（next-intl MIT ✓，`pnpm check:licenses` CI 已有）；测试在 web/ 内跑 `pnpm vitest`

## Design

### D1 next-intl 接入（新依赖 1 个：next-intl@4，MIT）

- `web/i18n/routing.ts`：`defineRouting({ locales: ['zh-CN', 'en'], defaultLocale: 'zh-CN', localePrefix: 'as-needed' })`；导出 `Locale` 类型
- `web/i18n/navigation.ts`：`createNavigation(routing)` 导出 `Link`/`router`/`redirect`/`useRouter`/`usePathname`——全站 Link 逐步替换（Phase 1 只替换壳层与切换器涉及的，Phase 2 全量）
- `web/i18n/request.ts`：`getRequestConfig` 按 locale 加载 `web/messages/zh-CN.json` / `en.json`
- **proxy.ts 组合**：`createMiddleware(routing)`（即 `intlMiddleware`）与本有 CSP 逻辑链式——先 CSP headers 处理，再 intl 中间件（或 wrapper 组合，保 nonce 注入不回归）；matcher 保持排除 api/_next
- `next.config.ts`：`createNextIntlPlugin('./i18n/request.ts')` 包裹

### D2 `[locale]` 路由段

- `web/app/[locale]/layout.tsx`：新根段布局（接收 params.locale，validate 后传 `setRequestLocale`）；现有 `app/layout.tsx` 的 html/body/字体/ThemeProvider/ApolloWrapper 迁入
- **`app/` 全部现有 page 目录移入 `app/[locale]/`**（orders/participations/settings/w/join/apply/approvals/courses/events/admin/(auth) 等；favicon/globals.css 不动）
- `generateStaticParams` 返回两 locale；`<html lang>` 动态化（zh-CN/en）
- `as-needed` 下 zh-CN URL 与现状逐字节一致（无前缀），`/en/*` 为英文；根路径 `/` 不重定向（zh-CN 直接渲染）
- metadata：`generateMetadata` 按 locale 出 title/description（en 文案 Phase 3 填，Phase 1 结构就位）

### D3 语言切换 UI

- **LanguageSwitcher 组件**（`components/language-switcher.tsx`）：客户端组件，两选项（中文/English），当前 locale 高亮；切换 = `router.replace(pathname 换前缀)` + 写 `cgc_locale` cookie（365d）+ 登录态静默 mutation `updateMyLocale`
- 公开页入口：landing 页 footer + (auth) 壳（auth-shell.tsx）角落——匿名可用（只写 cookie）
- 设置页入口：`settings/account/profile` 表单加「语言 / Language」下拉（ProfileSettingsForm 或独立小节），保存走 User.locale mutation
- 后端：User 加 `locale` attribute（:string，allow_nil?，public?，约束 `zh-CN|en`）+ migration + `update_locale` action（仅本人）+ GraphQL mutation `updateMyLocale(locale)`；已登录协商链读取：proxy 无法读 DB（边缘运行时），User.locale 在 **layout/服务端** 注入——登录用户带 User.locale 进页面时若与当前不同，服务端 redirect 到对应前缀（一次性对齐，之后 cookie 主导）

### D4 消息文件与 CI key 检查

- `web/messages/zh-CN.json`：Phase 1 建骨架 + **收录本 plan 新增的 UI 字符串**（切换器标签、设置页语言小节、`errors` namespace 迁入 PR #227 的 15 键 code 表——`payment-errors.ts` 的表数据迁入，函数改查 `t()`）；`en.json`：空对象 `{}`（占位）
- CI 脚本 `web/scripts/check-i18n-keys.mjs`：比对 zh-CN/en 的 key 集合（含嵌套），en 缺 key 即 fail（Phase 1 时 en 为空但 zh-CN 仅含新字符串 → 同步收录英文或暂以中文值占位，**取前者**：新 UI 字符串本 plan 直接双语落，量小 ~20 条）
- 约束进 `pnpm test` 前置或独立 `check:i18n` script 入 CI workflow

### D5 验证分层（按 repo AGENTS.md E2E 规范）

- 结构断言（主）：`/` zh-CN 渲染（html lang=zh-CN）、`/en` 前缀路由可达（html lang=en）、切换器点击后 URL/cookie 变化、登录用户 User.locale 持久化（GraphQL 断言）
- 交互走通：匿名切换 cookie 生效；登录切换 DB 持久 + 跨设备
- 现有测试全绿（vitest 669 基线，涉及 Link/route 的用例按 next-intl navigation 包装修 mock）

## Out of scope

- 存量 600–1000 条中文硬编码抽取（Phase 2，机械分批）
- en 翻译内容生产与本地化 UX 审查（Phase 3；术语表先行）
- 后端 Gettext 启用、邮件多语言（Phase 3+，Gettext 已在 deps）
- DB 内容双语 translations 子表（Phase 4，英文流量数据驱动启动）
- 小程序端（纯中文平台，明确排除；将来做用 @tarojs/plugin-i18n，key 与 web 对齐）
- hreflang/sitemap locale 化（Phase 3 随 en 内容一起）

## Tests（先于实施定案）

- 新增 `web/i18n/routing.test.ts`：locale 集合、default、as-needed 前缀行为（纯函数可测部分）
- 新增 `web/scripts/check-i18n-keys` 的测试（key 集合比对：相等过 / 缺 key fail）
- `language-switcher.test.tsx`：匿名切换（cookie 写入 mock）、登录切换（mutation 调用）、当前 locale 高亮
- settings profile 页测试：语言下拉存在 + 保存调用
- 后端：`updateMyLocale` action 测试（合法值写入 / 非法值拒绝 / 他人不可改——policy）+ GraphQL 契约（schema 变更快照）
- 既有测试回归：proxy 组合后 CSP 用例（如有）不回归；全量 vitest 绿

## Verification

- `cd web && pnpm typecheck && pnpm lint && pnpm test && pnpm build`
- `cd backend && mix precommit`（若含 User 变更）
- CI 全绿（含 `check:licenses`——next-intl MIT）
- agent-browser 冒烟：`/` 中文渲染 → 切换 en → URL `/en`、html lang=en、cookie `cgc_locale=en`；回切 zh-CN 无前缀 URL；dev 环境登录用户切换后 User.locale 行变化（psql 断言）

## Phases

| Phase | 内容 | 产出 |
|---|---|---|
| P1 | 后端 User.locale + mutation + 契约测试 | backend 绿 |
| P2 | next-intl 接入（routing/request/proxy 组合/next.config）+ `[locale]` 段迁移 + 切换器 + 双入口 + 消息骨架 + key 检查 CI | web 全绿 + agent-browser 冒烟 |
| P3 | `payment-errors.ts` 表迁入 errors namespace（函数改 t()）+ 既有测试 mock 修复 | 全量回归绿 |

## Rollback

- 无生产数据风险；DB migration 可逆（drop column locale）；proxy/路由改动单 commit 可 revert；en.json 空壳无副作用
- 主要风险：`app/` 目录大迁移（git mv 全量 page）——plan 拆独立 commit，revert 粒度清晰

## Signoff criteria

1. `/` 与现状逐字节一致（zh-CN 渲染，无 URL 变化）；`/en` 可达且 html lang=en
2. 匿名：切换写 cookie，下次访问生效；登录：User.locale 持久化，跨设备一致
3. CI key 检查在位（zh-CN/en key 集合相等才绿）
4. 三端套件全绿（backend / web / miniprogram 不涉改动但跑回归）
5. next-intl 过 license gate（MIT）

## Human decisions required

无阻塞决策——source locale 分层（中文 source / 英文 pivot）已拍板；本 plan 新增 UI 字符串 ~20 条双语直落（中文由 writer 按 plan 落，英文简单项直写，Phase 3 统一复审）。批准本 plan 即可进 writer02/advisor02 流水线。
