# Plan 2026-08-20-005 · 修复 #226：MCP token 闲置过期的可见性（展示标注 + active 上限口径）

## 背景

#222 已落地滚动过期（闲置 ≥90 天 `validate_token` 拒绝，惰性无新字段）。遗留两个可见性缺口：

1. **展示层不区分「闲置过期」与「有效」**：`web/lib/mcp.ts:28-37` `mapMcpToken` 的 status = `revokedAt ? "revoked" : "active"`——闲置过期 token（revoked_at nil）显示「有效」，学员季节性回流（寒暑假 >90 天）看到「token 正常但 MCP 401」的排障困惑。连带 `agents/page.tsx:236` `hasActiveToken` 误判「已连接」。
2. **过期 token 仍计入 10 枚 active 上限**：`token.ex:116-119` 计数 filter 仅 `is_nil(revoked_at)`——闲置过期 token 不可复活（validate_token 恒 :error 且永不 touch），纯死行占位，用户被迫手动撤销才能新签。

前置验证（scout 完成）：openclacky-ext 收到 401 已有反应式横幅（`hooks/on_tool_error.rb:14`、`panels/workspace/view.js:84-92`，引导重新 onboarding/重签 token）——**ext 零改动**；网站侧「闲置过期」标注是主动式预警，与 ext 反应式横幅互补。

## 决策

**web 本地判定 + backend 上限 filter**（scout 推荐路线）：

- 缺口① 在 `mapMcpToken` 本地派生 `idle_expired` 状态——GraphQL 已全量下发 `lastUsedAt/revokedAt/insertedAt`（`graphql_schema.ex:1694-1701`），零后端/零 GraphQL 改动。
- 缺口② 在 `token.ex` issue 计数 filter 追加排除闲置过期（SQL 谓词与 Elixir `idle_expired?/1` 整天边界严格对齐）。

拒绝「后端派生 idleExpired 字段」（单一事实源方案）：需改 `graphql_schema.ex:1694-1701` + resolver + SDL 重生，收益仅省一个 web 常量，且引入跨线文件冲突——惰性派生不落库哲学（#222 既定）由 web 本地判定延续。

## 实施单元（backend + web，单 PR）

### U1 backend：`token.ex` 上限口径

1. issue create 计数（:116-119）filter 追加排除 idle-expired（SQL 谓词与 `idle_expired?/1` 的 `DateTime.diff(...) >= 90` 整天语义对齐——恰 -90 天必须排除，`token_test.exs:180-188` 是回归锚）：

```elixir
cutoff = DateTime.add(DateTime.utc_now(), -@idle_expiry_days, :day)
__MODULE__
|> Ash.Query.filter(
  user_id == ^actor_id and is_nil(revoked_at) and
    ((is_nil(last_used_at) and inserted_at > ^cutoff) or
     (not is_nil(last_used_at) and last_used_at > ^cutoff))
)
|> Ash.count!(authorize?: false)
```

2. moduledoc（:13-18）与上限报错文案（:127）措辞同步：「active = 未撤销且未闲置过期」。

### U2 web：`mcp.ts` 状态派生

`McpTokenStatus` 加 `"idle_expired"`；`mapMcpToken`（:28-37）：

```ts
const IDLE_EXPIRY_DAYS = 90; // 对齐 backend Cgc2046.Mcp.Token @idle_expiry_days (token.ex:23)
const anchor = t.lastUsedAt ?? t.insertedAt;
const idleExpired = !t.revokedAt && anchor != null &&
  Math.floor((Date.now() - new Date(anchor).getTime()) / 86_400_000) >= IDLE_EXPIRY_DAYS;
status: t.revokedAt ? "revoked" : idleExpired ? "idle_expired" : "active"
```

UTC 比较，防时区 ±1 天漂移。

### U3 web：MCP 页渲染 + agents 页

1. MCP 页 `page.tsx:295-303`：徽章三分支——active→`l-badge-volunteer`、idle_expired→`l-badge-pending`（amber 警示，globals.css:1195-1199 已有）、revoked→`l-badge-danger`；文案 `t("idleExpired")`。撤销按钮门改 `status !== "revoked"`（idle_expired 仍可撤，清理死行）。
2. `agents/page.tsx:236` `hasActiveToken`：status 集中派生后自动排除 idle_expired——**预期行为变化**：闲置过期用户会重新看到连接引导（正确方向），验证即可。
3. `web/messages/{en,zh-CN}.json` workspaceMcp namespace（:803 附近）成对加 `idleExpired`：闲置过期（90 天未使用）/ Idle expired (unused for 90 days)。

### U4 测试

1. backend `token_test.exs`：上限 describe（:28-52）新增「回拨一枚到闲置过期（恰 -90 天）后仍可新签」用例（复用 :146-158 backdate helper）。
2. web `mcp.test.ts`：mapMcpToken 边界用例——-91 天→idle_expired、恰 -90 天→idle_expired、-89 天→active、revokedAt 优先于 idle 判定。
3. MCP 页 `page.test.tsx`：idle_expired token 渲染 amber 徽章 + 撤销按钮可用。
4. agents 页 `page.test.tsx`：idle_expired token → 连接引导重新出现。

## 验收标准

1. `mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿。
2. `pnpm typecheck / lint / test / build` 全绿。
3. 恰 -90 天边界三处一致：backend filter 排除、Elixir `idle_expired?` 判过期、web JS 判 idle_expired（各有测试锚）。
4. 10 枚上限：闲置过期 token 不再占位（U4.1 测试）。

## 非目标

- 不改 GraphQL schema/SDL（零后端契约变更）。
- openclacky-ext 零改动（401 反应式横幅现状已够）。
- 不做「闲置过期自动清理 job」（死行由用户手动撤销或保持占位显示）。
- 90 天阈值不做配置化（与 token.ex 一致用常量 + 注释互指）。

## 风险

| 风险 | 缓解 |
|---|---|
| SQL 与 Elixir 边界漂移（最高） | 恰 -90 天回归锚双侧测试；filter 与 `idle_expired?/1` 注释互指 |
| 90 天常量双写漂移 | 双侧注释互指（token.ex:23 ↔ mcp.ts IDLE_EXPIRY_DAYS） |
| 「active」语义变化文档漂移 | moduledoc/报错文案同步；CONTEXT.md:112「active 上限 10 枚」措辞在 PR body 记录提示（不强制改 CONTEXT） |
| agents 页行为变化 | U3.2 预期变化，测试固化 |
| messages 与 #206 线同文件 | 不同 namespace（workspaceMcp vs errors），键不冲突；合并串行（后线 rebase） |

## 关联

- Issue #226（本 plan 关闭目标）；上游 #222（滚动过期已落地）、#223 A4（advisory 来源）
- Scout 报告：`agent://Scout226`（2026-08-20，HEAD 取证）
- #222 plan：`docs/plans/2026-08-18-006-mcp-token-rolling-expiry.md:11`（本 plan 是其 out-of-scope 的遗留项）
