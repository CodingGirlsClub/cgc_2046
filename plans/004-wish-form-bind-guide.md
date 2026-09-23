# Plan 004: 写愿望被拒「档案未绑定」时给出绑定指引链接

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- web/components/flashback/wish-frames.tsx web/messages/zh-CN.json web/messages/en.json`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 建议在 003 之后（同文件，避免合并冲突；无逻辑依赖）
- **Category**: bug（产品契约缺口 KTD7/U8 的最小收口）
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

设计文档（`docs/plans/2026-09-21-1945-feat-flashback-wishes-tree-plan.md`，KTD7/U8）写明：写愿望对「已登录**且已认领**校友」开放，「未认领登录用户被引导认领」。现状只做到了一半：公开树页的「写下我的愿望」入口只判 `authed`（`wishes-wall.tsx:319`），登录但未认领档案（viewer）的用户可以完整写完 500 字愿望，提交时才被后端以 `flashback_person_not_bound` 拒绝（`alumni_projection.ex:69`），屏幕上出现一行错误文案——**没有任何去认领的行动出口**。

数据源前置判定（进入页面前就知道用户是否已认领）需要扩展 `me` 查询，是 M 级跨端改动，本计划不做。本计划做最小收口：错误态出现时，把既有文案旁边补一个指向 `/flashback/enter`（站内登录/找回/绑定入口，公开树页未登录写愿望已跳这里）的链接，让用户有路可走。

## Current state

- `web/components/flashback/wish-frames.tsx` — `WishFormModal` 是树页与长廊共用的写愿望表单。
- `web/app/[locale]/flashback/wishes/wishes-wall.tsx:317-323` — 树页入口（未登录 → `Link href="/flashback/enter"`，登录 → 开 `WishFormModal`）。
- 后端拒绝链（只读参考）：`flashback_identity` → `AlumniProjection.resolve_person` 失败 → `{code: "flashback_person_not_bound", message: "no archive bound"}`（`alumni_projection.ex:69`）。

`WishFormModal` 的 `submit` 错误分支（`wish-frames.tsx`，`submit` 函数内 catch）：

```tsx
		} catch (e) {
			// 业务错误（quota_exceeded / content_rejected / city_unknown）按 code 映射
			// errors 文案；无 code / 未知 code 兜底 database_error（错误文案纪律）
			const detail = graphqlErrorDetails(e);
			setError(errorT(detail?.code, tErrors("database_error")));
			// 额度被拒即触发胶囊 refetch（F2）：refetch 完成后 prop 变 0 → 额度行变
			// 用完文案 + 提交禁用；模态保持打开
			if (detail?.code === "flashback_wish_quota_exceeded") onDone(null);
		}
```

错误展示位（表单 JSX 内，已存在）：

```tsx
				{error && (
					<p role="alert" className="fb-hint">
						{error}
					</p>
				)}
```

既有文案（`web/messages/zh-CN.json` → `errors.flashback_person_not_bound`）：「当前账号还没有绑定闪念间档案——先从专属链接进入一次吧。」（en 同 key 已有）。

i18n 约定：新 key 必须同时加进 `zh-CN.json` 与 `en.json`；CI `scripts/check-i18n-keys.mjs` 强制双语 100% 覆盖，漏一侧会挂 CI。key 风格：camelCase（`flashback.wish` 命名空间现有 keys 如 `viewOnTree`、`quotaExhausted`）。

`Link` 组件：`import { Link } from "@/i18n/navigation";`（`wish-frames.tsx:6` 已有）。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0 |
| 单测 | `cd web && pnpm vitest run components/flashback` | 全部 pass |
| lint | `cd web && npx eslint components/flashback/wish-frames.tsx` | 0 errors |
| i18n 覆盖 | `cd web && node scripts/check-i18n-keys.mjs` | exit 0 |

## Scope

**In scope**:
- `web/components/flashback/wish-frames.tsx`（仅 `WishFormModal`）
- `web/messages/zh-CN.json`（`flashback.wish` 命名空间 +1 key）
- `web/messages/en.json`（同上）
- `web/components/flashback/future-frames.test.tsx`（追加用例；WishFormModal 的既有测试宿主）

**Out of scope**:
- **禁止任何「预先禁用/前置判定」探索**：进入表单前就知道用户是否已认领，需要后端 `me` 查询暴露档案绑定态——该数据源当前**不存在**，是独立的跨端立项。本计划严格钉在模态内引导：只有提交被 `flashback_person_not_bound` 拒绝后才出现链接。不要去找/加 `me` 字段、不要在 `wishes-wall` 入口做资格判断、不要新增任何预查请求。
- 后端任何文件。
- `wishes-wall.tsx`（入口逻辑不动）。
- `WishFrames`/`WishModal`（003 已覆盖其错误处理）。

## Git workflow

- 当前 worktree 分支继续；commit style：`feat(flashback): bind-archive guide link when wish submit hits person_not_bound`
- 只本地 commit，不 push。

## Steps

### Step 1: 加 i18n key（双语同步）

`web/messages/zh-CN.json` 的 `flashback.wish` 对象内加：

```json
"bindGuideCta": "去绑定闪念间档案"
```

`web/messages/en.json` 同位置加：

```json
"bindGuideCta": "Bind your flashback archive"
```

**Verify**: `cd web && node scripts/check-i18n-keys.mjs` → exit 0。

### Step 2: 错误态渲染指引链接

`WishFormModal` 内新增状态：

```tsx
	const [bindGuide, setBindGuide] = useState(false);
```

`submit` 的 catch 分支里，紧邻 `setError(...)` 加：

```tsx
			setBindGuide(detail?.code === "flashback_person_not_bound");
```

错误展示位改为（保持 `role="alert"`）：

```tsx
				{error && (
					<p role="alert" className="fb-hint">
						{error}
						{bindGuide && (
							<>
								{" "}
								<Link href="/flashback/enter">{t("bindGuideCta")}</Link>
							</>
						)}
					</p>
				)}
```

`bindGuide` 与 `error` 必须**成对清零**：`submit()` 开头的 `setError(null)` 处紧跟着写 `setBindGuide(false)`。不写成「若你更愿意……也可以」这种开放条——否则 error 从 `flashback_person_not_bound` 切到 `database_error` 时，bindGuide 仍为 true，alert 会带挂错的链接。这是行为对称性硬要求。

**Verify**: `cd web && npx tsc --noEmit` → exit 0。

### Step 3: 追加测试

先读 `future-frames.test.tsx:277-290` 的「机审拒绝：flashback_content_rejected」用例（拒绝形状已验证：`mockRejectedValue({errors: [{message, extensions: {code}}]})`）。同手法追加一条：

用例：`createWish` reject 且 code 为 `flashback_person_not_bound` → 提交后断言：

1. `expect(await screen.findByRole("alert")).toHaveTextContent("当前账号还没有绑定闪念间档案——先从专属链接进入一次吧。")`——zh locale 实际值原样写入（`web/messages/zh-CN.json` 的 `errors.flashback_person_not_bound`，不要截断尾句）。
2. 同一 alert 元素内的链接（`within(alert).getByRole("link")`），`getAttribute("href")` 满足 `/^\/(en\/)?flashback\/enter($|[?#])/`——zh/en 双 locale 都兼容（zh 无前缀、en 前缀 `/en`）。

**Verify**: `cd web && pnpm vitest run components/flashback` → 全 pass。

## Test plan

- 新用例 1 条：`person_not_bound` 拒绝 → 错误文案 + 绑定指引链接同时可见。
- 既有 future-frames / corridor 测试不许回归。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && node scripts/check-i18n-keys.mjs` exit 0（双语覆盖）
- [ ] `cd web && pnpm vitest run components/flashback` 全 pass
- [ ] `grep -n "bindGuideCta" web/messages/zh-CN.json web/messages/en.json` 各命中 1 次
- [ ] `git status` 只有 in-scope 四文件
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- `WishFormModal` 的 submit/catch 与摘录不符（003/005 已先行改动同文件）——以现场代码为准做等价插入，若结构变化过大先报告。
- `errors.flashback_person_not_bound` 文案不存在或语义已变——报告，不要自行改 errors 文案。
- 你发现自己在考虑「提交前判断用户是否已认领」（任何入口预禁用/预引导）——越界，停下；本计划只有模态内错误态引导一条路。

## Maintenance notes

- 后续增强（本计划明确不做）：扩展 `me` 查询返回档案绑定态，`wishes-wall` 入口对未认领用户直接展示「绑定档案」引导而非打开表单。这是产品契约（KTD7/U8）的完整形态；本计划只是让失败路径可走。
- reviewer 重点看：链接只应出现在 `bindGuide` 为 true 时（其他错误码不带链接）。
