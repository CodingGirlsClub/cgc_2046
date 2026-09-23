# Plan 002: 公开树加载加乱序守卫——慢响应不再覆盖新数据

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- "web/app/[locale]/flashback/wishes/wishes-wall.tsx" "web/app/[locale]/flashback/wishes/wishes-wall.test.tsx"`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none（与 001 不同文件，可并行；若 006 已先做，先读 006 的改动）
- **Category**: bug（correctness / race）
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

许愿树墙的公开数据加载 effect 在 `city / seed / voter / loadGeneration` 任一变化时重发查询，但**没有过期响应守卫**。用户快速连点「换一批」或快速切换城市时，两个请求同时在飞；先发出、后返回的旧响应会把新数据覆盖掉——结果是：选着「成都」的地图与标题，面板里挂的是上一批愿望，且无任何报错。弱网手机上这不难复现，属于「偶发、高困惑度」类 bug。

同一组件树里已有正确范式：`wishes-page.tsx` 的 `?item=` 校验 effect 用 `cancelled` 标志守卫（`:71-95`）。本计划把同款守卫补到墙的加载 effect，消除同文件内的模式不一致。

## Current state

- `web/app/[locale]/flashback/wishes/wishes-wall.tsx` — 墙本体；数据加载 effect 在 `:158-178`。
- `web/app/[locale]/flashback/wishes/wishes-wall.test.tsx` — 既有 6 条测试；mock 手法（`vi.mock("@/lib/apollo-client")` 按 query 分发 + `wallQuery` mock fn）直接沿用。

`wishes-wall.tsx:158-178` 现状：

```tsx
	// 公开树加载（失败可重试）：city/seed/voterKey 变化或重试时重拉。
	// 不同步置 loading（react-hooks/set-state-in-effect）：初始态即 "loading"；
	// 变化重拉沿用旧数据平滑替换；显式重试在 handler 置 loading。
	useEffect(() => {
		client
			.query({
				query: FLASHBACK_PUBLIC_WISHES,
				variables: { city: city || null, seed, limit: 60, voterKey: voter },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				setWishes((data?.flashbackPublicWishes ?? []) as FlashbackPublicWish[]);
				setLoadState("ready");
			})
			.catch(() => setLoadState("failed"));
	}, [city, seed, voter, loadGeneration]);
```

对照的正确范式（`wishes-page.tsx:74-95`，已存在的同仓库先例）：

```tsx
	useEffect(() => {
		if (!item) return;
		let cancelled = false;
		client.query({ ... })
			.then(({ data }) => {
				if (cancelled) return;
				...
			})
			.catch(() => { if (!cancelled) setDirect("gone"); });
		return () => { cancelled = true; };
	}, [item]);
```

触发链（写测试要用）：「换一批」按钮 → `shuffle()` → `setSeed(crypto.randomUUID())` → effect 重跑。连点两次 = 两个 in-flight 查询。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0 |
| 单测 | `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` | 全部 pass |
| lint | `cd web && npx eslint "app/[locale]/flashback/wishes"` | 0 errors |

## Scope

**In scope**:
- `web/app/[locale]/flashback/wishes/wishes-wall.tsx`（仅该 effect 及其注释）
- `web/app/[locale]/flashback/wishes/wishes-wall.test.tsx`（追加用例）

**Out of scope**:
- **在 effect 里加任何 `setLoadState(...)` / `setWishes(...)` 同步置位**——「变化重拉沿用旧数据平滑替换」是有意语义（注释写明了），只允许加 `cancelled` 守卫。在 effect 里同步置 loading 会引入加载闪断，且仓库的 `react-hooks/set-state-in-effect` lint 规则会直接拦下；如果你的 diff 触发这条 lint，说明你改错了方向。
- `voices-wall.tsx` 与其他页面的同类 effect——本计划只修许愿树（聚焦范围；voices 是否有同病留给后续审计，不要顺手改）。
- `wishes-page.tsx`（001 在改）。
- 期待/乐观更新相关代码（`toggleExpect` 等）——#806 F2 模式已正确，勿动。

## Git workflow

- 当前 worktree 分支继续；commit style 照 repo：`fix(flashback): guard public wall loads against out-of-order responses`
- 只本地 commit，不 push。

## Steps

### Step 1: 给加载 effect 加 cancelled 守卫

把 `wishes-wall.tsx:158-178` 的 effect 改成（保持原注释，在其后追加一行说明守卫）：

```tsx
	useEffect(() => {
		// 乱序守卫：city/seed 快速连点时，后发先至的新响应生效，晚到的旧响应丢弃
		let cancelled = false;
		client
			.query({
				query: FLASHBACK_PUBLIC_WISHES,
				variables: { city: city || null, seed, limit: 60, voterKey: voter },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => {
				if (cancelled) return;
				setWishes((data?.flashbackPublicWishes ?? []) as FlashbackPublicWish[]);
				setLoadState("ready");
			})
			.catch(() => {
				if (cancelled) return;
				setLoadState("failed");
			});
		return () => {
			cancelled = true;
		};
	}, [city, seed, voter, loadGeneration]);
```

注意：`.catch` 也要守卫（晚到的失败不应把新数据页打成「加载失败」）。

**Verify**: `cd web && npx tsc --noEmit` → exit 0。

### Step 2: 追加乱序回归测试（受控 promise，不依赖 mock 消费顺序）

在 `wishes-wall.test.tsx` 顶部，把既有 `vi.hoisted` 块扩为可手控的 deferred 队列（保持 `wallQuery` 等原导出不变）：

```tsx
const { wallQuery, citiesQuery, expectRunner, deferred } = vi.hoisted(() => ({
	wallQuery: vi.fn(),
	citiesQuery: vi.fn(),
	expectRunner: vi.fn(),
	// 手控 promise：push 一个存根，测试自行决定何时 resolve——乱序场景的
	// 时间线由测试自己排，不依赖 once-mock 的消费顺序（脆弱，且本用例正是
	// 要绕开「注册顺序=完成顺序」的巧合）
	deferred: [] as Array<{
		resolve: (v: { data: { flashbackPublicWishes: FlashbackPublicWish[] } }) => void;
		reject: (e: unknown) => void;
	}>,
}));
```

`beforeEach` 里追加一行 `deferred.length = 0;` 清空。

用例本体（时间线：seed1 请求挂起 → 点「换一批」触发 seed2 → seed2 立即落地 → 再放行 seed1 的慢响应）：

```tsx
	it("乱序响应不覆盖新数据：晚到的旧 seed 响应被丢弃", async () => {
		render(<WishesWall showIntro={false} />);
		await screen.findByText("愿望 w1"); // 初始加载完成

		// seed1：挂起
		wallQuery.mockImplementationOnce(
			() => new Promise((resolve, reject) => deferred.push({ resolve, reject })),
		);
		// seed2：立即返回
		wallQuery.mockResolvedValueOnce({
			data: { flashbackPublicWishes: [wish("w-latest")] },
		});

		fireEvent.click(screen.getByText("换一批"));   // → seed1 请求（挂起）
		fireEvent.click(screen.getByText("换一批"));   // → seed2 请求（立即落地）
		await screen.findByText("愿望 w-latest");

		// 此刻放行 seed1 的迟到响应——守卫应将其丢弃
		deferred[0].resolve({ data: { flashbackPublicWishes: [wish("w-stale")] } });
		await waitFor(() => {
			expect(screen.queryByText("愿望 w-stale")).toBeNull();
		});
		expect(screen.getByText("愿望 w-latest")).toBeTruthy();
	});
```

**Verify**: `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` → 全 pass（原 6 条 + 新 1 条）。先用 `git stash` 暂存你的源码改动（保留测试）跑一次确认新用例**失败**（seed1 慢响应覆盖了 seed2 数据 → 「愿望 w-latest」消失），恢复源码改动后**通过**——red→green 证据写进报告。

## Test plan

- 新用例仅 1 条（上述乱序场景），钉住本 bug 的行为契约：**用户看到的必须是最后一次请求的数据**。
- 既有 6 条不许回归。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` 全 pass（≥7 条）
- [ ] `grep -n "cancelled" "web/app/[locale]/flashback/wishes/wishes-wall.tsx"` 命中加载 effect
- [ ] `git status` 只有 in-scope 两文件
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- 现状代码与摘录不符（effect 已被其他人改过）。
- 新测试无法按 deferred-promise 手法稳定复现（连点两次只触发一次 query）——说明 shuffle/effect 链路已变，报告实际行为。

## Maintenance notes

- 未来若把「换一批」改成 offset 翻页（后端 `flashbackPublicWishes` 已支持 `offset`），本守卫依然必要且够用——守卫按 effect 实例生命周期工作，与分页参数无关。
- reviewer 重点看：`.catch` 分支也被守卫（常见漏改点）。
