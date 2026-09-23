# Plan 005: 树页写愿望额度被拒后本地锁定——不再无限重提交

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- web/components/flashback/wish-frames.tsx web/components/flashback/future-frames.test.tsx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 建议在 003/004 之后（同文件；无逻辑依赖）
- **Category**: bug（UX 死循环）
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

年度许愿额度是 3 条/年（含私有与已软删，删除不退还）。长廊（capsule）场景里 `WishFormModal` 拿到 `myWishQuotaRemaining` prop：额度行可见、用完即禁用提交、被拒时 refetch 胶囊（F2）。但公开树页 `wishes-wall.tsx:562-564` 挂同一组件时传的是：

```tsx
	<WishFormModal
		token={null}
		busy={false}
		myWishQuotaRemaining={null}
		...
```

`myWishQuotaRemaining === null` → `quotaExhausted === false` → 额度行不渲染、提交恒可用。树页又没有现成的个人额度查询（capsule 查询要求 person 身份）。结果：额度用完的用户在树页每次提交都收到错误文案「今年许愿名额已用完…」，关闭、重写、再提交、再被拒——按钮永远亮着，文案永远拒绝，是一个体验死胡同。

正确的数据源方案（树页拉额度）需要新的登录态查询，M 级跨端改动，本计划不做。本计划做组件内最小修复：**收到 `flashback_wish_quota_exceeded` 拒绝后，组件本地置为额度用完态**——复用现有 `quotaExhausted` 渲染分支（用完文案 + 提交禁用），零数据源需求。用户至少得到明确的终态而不是可重试的假象。

## Current state

- `web/components/flashback/wish-frames.tsx` — `WishFormModal`。
- `web/components/flashback/future-frames.test.tsx` — `WishFormModal` 既有测试宿主（含「额度被拒 refetch」用例，本计划的对照模式）。

`WishFormModal` 关键现状（行号为 `6cd74306` 时点）：

```tsx
	const quotaExhausted = myWishQuotaRemaining === 0;
	...
	const submit = async () => {
		const trimmed = content.trim();
		if (!trimmed || loading || busy || quotaExhausted) return;
		setError(null);
		try {
			const { data } = await createWish({ ... });
			...
		} catch (e) {
			const detail = graphqlErrorDetails(e);
			setError(errorT(detail?.code, tErrors("database_error")));
			// 额度被拒即触发胶囊 refetch（F2）：refetch 完成后 prop 变 0 → 额度行变
			// 用完文案 + 提交禁用；模态保持打开
			if (detail?.code === "flashback_wish_quota_exceeded") onDone(null);
		}
	};
```

额度行渲染（表单顶部，已存在）：

```tsx
				{myWishQuotaRemaining !== null && (
					<p className="fb-wish-modal-quota">
						{quotaExhausted ? t("quotaExhausted") : t("quotaRemaining", { count: myWishQuotaRemaining })}
					</p>
				)}
```

提交按钮（已存在）：

```tsx
					<button
						type="button"
						className="fb-wish-modal-submit"
						disabled={loading || busy || quotaExhausted}
						...
```

既有文案：`flashback.wish.quotaExhausted` = 「今年许愿名额已用完（每年最多 3 条，删除不退还名额）。」（en 同 key 已有，无需新增 i18n key。）

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0 |
| 单测 | `cd web && pnpm vitest run components/flashback` | 全部 pass |
| lint | `cd web && npx eslint components/flashback/wish-frames.tsx` | 0 errors |

## Scope

**In scope**:
- `web/components/flashback/wish-frames.tsx`（仅 `WishFormModal`）
- `web/components/flashback/future-frames.test.tsx`（追加用例）

**Out of scope**:
- `wishes-wall.tsx`——不为树页接额度数据源（那是独立的数据方案，见 Maintenance notes）。
- 后端任何文件。
- 新 i18n key（复用 `quotaExhausted`，双语已齐）。

## Git workflow

- 当前 worktree 分支继续；commit style：`fix(flashback): lock wish submit locally after quota rejection`
- 只本地 commit，不 push。

## Steps

### Step 1: 引入本地额度锁定态

`WishFormModal` 内：

1. 新增状态：

```tsx
	// 服务端额度拒绝后的本地锁定（树页场景 myWishQuotaRemaining=null，prop 路径
	// 失效——用提交被拒这个事实本身作为用完信号，模态内给出终态而非可重试假象）
	const [quotaBlocked, setQuotaBlocked] = useState(false);
```

2. 统一判定（替换现有 `const quotaExhausted = myWishQuotaRemaining === 0;`）：

```tsx
	const quotaExhausted = myWishQuotaRemaining === 0 || quotaBlocked;
```

3. `submit` 的 catch 分支，在现有 `if (detail?.code === "flashback_wish_quota_exceeded") onDone(null);` 处追加一行：

```tsx
			if (detail?.code === "flashback_wish_quota_exceeded") {
				setQuotaBlocked(true);
				onDone(null);
			}
```

4. 额度行渲染放宽为「prop 可知或本地已锁定」时显示（否则树页被拒后看不到用完文案行，只有提交按钮被禁）：

```tsx
				{(myWishQuotaRemaining !== null || quotaBlocked) && (
					<p className="fb-wish-modal-quota">
						{quotaExhausted ? t("quotaExhausted") : t("quotaRemaining", { count: myWishQuotaRemaining })}
					</p>
				)}
```

提交按钮的 `disabled={loading || busy || quotaExhausted}` 无需改——`quotaExhausted` 已涵盖新状态。

**Verify**: `cd web && npx tsc --noEmit` → exit 0。

### Step 2: 追加测试

先读 `future-frames.test.tsx` 既有「额度被拒 refetch」（额度胶囊场景用例）与「机审拒绝：flashback_content_rejected」（`:277-290`——拒绝形状 `mockRejectedValue({errors: [{message, extensions: {code}}]})` 直接照抄，把 code 换成 `flashback_wish_quota_exceeded`）。追加一条：

用例：`myWishQuotaRemaining` 传 `null`（树页形态）+ `createWish` reject 且 code 为 `flashback_wish_quota_exceeded` → 提交后断言（**三条**：两条钉 quota-row 结构、一条钉 alert 清除——alert 文案与 quota-row 文案都含「今年许愿名额已用完」，裸 `findByText` 无法区分）：

1. 用 `document.querySelector(".fb-wish-modal-quota")` 取出额度行节点，断言其 `textContent` 包含「今年许愿名额已用完」（zh 实际全串）。这是本计划新增的渲染分支，裸 `findByText` 会在旧错误 alert 上假性通过。
2. 提交按钮（`getByRole("button", { name: "许下这个愿" })`）为 disabled——直接测 `quotaExhausted || quotaBlocked` 的汇合逻辑。
3. `expect(screen.queryByRole("alert")).toBeNull()`——错误文案已被「额度用完终态」取代（如果你选择保留 alert 不清，请在提交前向 reviewer 说明理由；默认形态是 `setError(null)` 与 `setQuotaBlocked(true)` 同刻发生，alert 让位 quota-row）。

**Verify**: `cd web && pnpm vitest run components/flashback` → 全 pass；新用例在未修复代码上应失败（提交按钮不会禁用），修复后通过。

## Test plan

- 新用例 1 条：`null` 额度 prop + 服务端 quota 拒绝 → 本地锁定终态（文案 + 禁用）。
- 既有额度相关用例不许回归（prop 驱动路径行为不变：`myWishQuotaRemaining === 0` 依旧禁用）。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && pnpm vitest run components/flashback` 全 pass
- [ ] `grep -n "quotaBlocked" web/components/flashback/wish-frames.tsx` 命中 ≥3 处（state、判定、catch）
- [ ] `git status` 只有 in-scope 两文件
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- `WishFormModal` 结构与摘录不符（003/004 已先行改动）——做等价插入；冲突过大先报告。
- 发现 `myWishQuotaRemaining` 在树页场景已有真实数据源（比如有人已接入个人额度查询）——本计划前提失效，报告。

## Maintenance notes

- 完整方案（后续可立项）：树页对登录用户拉取个人额度（新公开登录态查询或扩 `me`），`wishes-wall` 把真实 `myWishQuotaRemaining` 传给 `WishFormModal`——届时 `quotaBlocked` 仅作为两查询间的窗口期兜底，保留无害。
- reviewer 重点看：长廊场景（prop 驱动）行为不变——`myWishQuotaRemaining` 为具体数字时，本计划零影响。
