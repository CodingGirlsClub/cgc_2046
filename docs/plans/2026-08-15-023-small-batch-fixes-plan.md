# Plan 023 · 小修批（组6：#84 关闭 + #87 defer + #86 安全修复）

- 日期：2026-08-15
- 状态：待评审
- 决策依据：Scout023 取证；用户拍板组6
- 处理目标：#84（判定已修复，关闭）、#87（维持 defer）、#86（真实安全缺口，本 plan 唯一代码交付）

## 1. 取证判定

| Issue | 判定 | 依据 |
|---|---|---|
| #84 面包屑 slug | **已被 ADR-0004 路由迁移修复，直接关闭** | 旧 `/profile`/`/profile/portfolio` 路由已不存在；现面包屑在 per-workspace profile 页渲染 `summary?.workspaceName ?? slug`（`page.tsx:111`），`workspaceName` 来自 ME_WORKSPACES 的 `name`（`workspace.ts:193-207` → `profile.ts:319-332`），slug 仅兜底 |
| #87 join 卡片抽取 | **维持 defer** | 候选 5 Phase 3e 明确按 ponytail 推迟（`web/workflows/plans/2026-08-05-profile-join-page-split.md:150-153`）；三张卡仍内联（`join/page.tsx:250-318`）但共享样式已在（`globals.css:1773-1780`），无行为问题 |
| #86 邮箱枚举 | **真缺口，需修** | 重复邮箱报 `has already been taken` + fields[email]，新邮箱成功——payload 结构、错误文案、时延三者可区分（`graphql_schema.ex:419-464`）；测试钉住了枚举行为（`graphql_auth_test.exs:39-77` 断言 already been taken）；前端直透展示（`auth.ts:88-100` → `use-auth-submit.ts:89-99`） |

## 2. #86 修复方案

issue 列三向：A 保留枚举（现状）、B 全部失败统一文案、C 延迟/占位注册。

**选 B（统一文案）**，理由：C（占位注册）改动注册语义且引入幽灵账号清理问题；A 是现状漏洞。B 一行级改动覆盖响应差异，时延差异通过恒定工作量对齐缓解。

### U1 后端
1. `graphql_schema.ex:419-464` sign_up resolver：Ash.Invalid 的 `unique_email` 冲突分支不再透传 `has already been taken` + fields，改返回通用错误 `registration_failed`（与既有未知错误分支同码同形）；**非邮箱类校验错误（格式等）保持结构化**——仅抹平「该邮箱已存在」这一可枚举信号。
2. 响应形状：成功/失败均 result/errors 结构不变；重复邮箱与新邮箱非法输入的 errors 同形（message 均 generic，无 fields[email]）。

### U2 前端
1. `web/lib/graphql/auth.ts:88-100` `signUpErrorMessage`：`registration_failed` → 「注册失败，请检查信息后重试」；移除对 `already been taken` 的依赖映射（如有）。
2. `use-auth-submit.ts:89-99` 直透链不变（文案源头已友好）。

### U3 测试
1. 后端：改 `graphql_auth_test.exs:39-77` 重复邮箱断言——从 `already been taken` 改为 generic 同形断言（成功与重复邮箱的响应 shape 对比测试，钉住不可区分性）；新增「重复邮箱与非法格式错误的 fields 均不含 email」断言。
2. 前端：`signUpErrorMessage` generic 映射断言。

## 3. #84/#87 处置（零代码）

- #84 关闭评论：ADR-0004 per-workspace 迁移已修复（file:line 对照），slug 仅空名兜底；不复现即关。
- #87 维持 defer：评论引用候选 5 ponytail 决策原文，不改状态。

## 4. 验收标准

1. 重复邮箱与全新邮箱注册失败响应不可区分（形状/文案/字段三同）；合法注册不受影响；格式错误仍可指导用户。
2. 既有 auth 测试套件改后全绿；backend ×2 seeds + web 全套绿。
3. #86 关闭（修复说明）、#84 关闭（已修复对照）、#87 defer 评论落盘。

## 5. 实施顺序

U1 → U2 → U3 → 自查 → commit 不 push → `/tmp/cgc_2046-writer23-report.md`；#84/#87/#86 的 issue 操作在 PR 合并后由 orchestrator 执行。

## 6. Assumptions

1. `registration_failed` 错误码在 SDL/前端映射已有先例（resolver 未知错误分支已用——writer 核对 `graphql_schema.ex:460-464`）。
2. 无其它消费方依赖 `already been taken` 文案（grep web/miniprogram；小程序注册走同 GraphQL 则同样受益）。
