# MCP 连接 token 滚动过期（#222 / #211 裁决选项 3）

轨道 006 · 2026-08-18 · 状态：待批准 → 已批准（用户会话内已裁决选项 3，本文即执行方案）

## 目标

MCP 连接 token 增加**滚动过期**：连续 90 天未使用即失效。正常使用不断、无需重签；无固定 TTL、无新字段、无迁移。

**Out of scope**：
- 固定 TTL / expires_at 字段（已否决，见 #211 评论）
- UI/GraphQL 展示「闲置过期」标注（#222 可选项，不做）
- 清理 job（过期 token 不回收，审计行保留——与 revoked 同语义）

## 现状证据（HEAD）

- `backend/lib/cgc_2046/mcp/token.ex:274-295`：`validate_token/1` 过滤仅 `token_hash == ^hash and is_nil(revoked_at)`，无时间维度
- 属性（L31-66）：`token_hash` / `name` / `user_id` / `last_used_at`（nil=从未用）/ `revoked_at` + `inserted_at`/`updated_at`
- 鉴权唯一入口 `Cgc2046Web.Plugs.McpAuthPlug`（`plugs/mcp_auth_plug.ex:21`）→ `validate_token/1`
- 测试直改库回拨时间的先例：`test/cgc_2046/mcp/pending_operation_test.exs:73-80`、`token_race_test.exs:44-48`

## 设计

`token.ex` 两处改动：

1. module attribute `@idle_expiry_days 90`（满足 #222「可配置」的最低形态；常量即可，运行时 config 属 YAGNI——测试用回拨时间而非调参）。
2. `validate_token/1`：查到 token 后、触碰 `last_used_at` 前，追加 Elixir 层判断：

```elixir
anchor = token.last_used_at || token.inserted_at
if DateTime.diff(DateTime.utc_now(), anchor, :day) >= @idle_expiry_days, do: :error
```

- 判断在 Elixir 层而非 Ash filter：单行查询已按唯一 hash 命中至多一行，无查询性能差异；避免 expr/fragment 复杂化。
- **边界语义**：距今 ≥ 90 天（整天数）→ 失效；89 天 23:59 → 有效。
- 过期 token 与无效 token 同样塌缩为 `:error`（不泄露存在性，同现行 #260 注释纪律）。
- 过期 token 的 DB 行保留原样（不置 revoked_at——那是用户动作的审计语义；过期是派生状态，惰性判定，同 PendingOperation expired 派生范式）。

## 影响面

| 文件 | 改动 |
|---|---|
| `backend/lib/cgc_2046/mcp/token.ex` | `@idle_expiry_days` + `validate_token/1` 过期判断 + moduledoc 安全约束补一行 |
| `backend/test/cgc_2046/mcp/token_test.exs` | 新 describe「滚动过期（#222）」5 用例 |

不改：plug、GraphQL、迁移、UI。

## 测试（先于实现定义成功标准）

`token_test.exs` 新 describe，用 Ecto 直改库回拨（先例范式）：

1. 新签发 token（inserted_at ≈ now）→ `validate_token` 通过
2. `inserted_at` 回拨 -91 天（last_used_at nil）→ `:error`
3. 边界：`inserted_at` 回拨恰 -90 天 → `:error`（>= 语义）
4. `inserted_at` 回拨 -100 天 + `last_used_at` 回拨 -1 天 → 通过（活动重置窗口；覆盖 nil-fallback 分支的另一侧）
5. 过期 token 行未被动过：`revoked_at` 仍为 nil（过期 ≠ 撤销，审计语义不混淆）

现有套件回归：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test`（×2 seeds）。

## 安全/回滚

- 无新攻击面：判断收窄鉴权，不放宽
- 回滚 = revert 单 commit，无 schema 变更
- 并发：`touch_last_used` 与过期判断的竞态——过期判定读的是刚查出的行，窗口内最多放行一次已闲置调用，无危害

## 验收对照（#222）

- [x] ≥90d 未用 → `:error`（用例 2/3）
- [x] 正常使用不受影响（用例 1/4）
- [x] 错误形态一致塌缩（设计：同一 `:error`）
- [x] 测试覆盖 nil fallback + touch 重置（用例 4）
- [x] CONTEXT.md 已落文（本仓库上一 commit）

## 人类决策

- 无待决策项（选项 3 已由用户本会话裁决）
