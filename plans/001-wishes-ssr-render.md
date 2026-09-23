# Plan 001: 许愿树公开页参与 SSR——分享落地页不再白屏

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- "web/app/[locale]/flashback/wishes/"`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (SEO / first-paint)
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

`/flashback/wishes` 是许愿树公开传播页（分享链接 `?item=<wish_id>` 的落地页，设计文档拍板「无上线门，部署即公开」）。当前整页在服务端渲染为空：服务端快照下 `introSeen` 恒为 `null`，组件直接 `return null`，HTML body 只有一个 `<title>`。爬虫拿到零正文的页面，弱网移动端用户在 JS 下载执行前全程白屏。

空渲染是从 voices 页照抄的：voices 有开场动画，先渲染再播动画是必要的；**wishes 墙没有任何开场动画**——`showIntro` prop 在 `wishes-wall.tsx` 里的唯一用途是把「已看过开场」写进 localStorage（跨页共享，KTD8）。因此对 wishes 而言「等 introSeen 确认再渲染」没有守护任何东西，纯粹丢掉了 SSR。

**修复边界（钉死）**：本计划只恢复既有组件树的 SSR 输出——header 品牌/nav CTA、hero 标题与导语、面板加载提示文案（「正在挂愿望…」，`flashback.wishes.loading` 的实际值）、「换一批」等静态动作按钮。愿望卡片数据**保持客户端拉取不变**（`WishesWall` 的 `network-only` useEffect 查询原样保留），不引入任何服务端数据预取：`page.tsx` 不动、不动 Apollo/RSC 边界、不动 `fetchPolicy`。爬行器的收益来自页头/文案/结构，愿望列表本就依赖 voterKey 等客户端状态，属于客户端职责。

**隐含副作用（先想清楚再动手）**：`WishesWall` 是 `"use client"` 组件，删守卫后它开始参与服务端预渲染，其初始渲染走的是「`loadState === "loading"`」分支——面板区 SSR 输出的是 `t("loading")`「正在挂愿望…」文案而非愿望卡（与边界一致，属于加载壳）。消灭白屏是收益；拥抱面板加载壳进 SSR 是本计划的既定取舍，不要为了让面板不闪加载壳文案去做任何服务端数据预取（越界）。

## Current state

- `web/app/[locale]/flashback/wishes/wishes-page.tsx` — 客户端入口：`?item=` 直达校验 + 开场记忆 + 挂 `WishesWall`。
- `web/app/[locale]/flashback/wishes/wishes-wall.tsx` — 墙本体（本计划不改它，只是确认 `showIntro` 的语义）。

`wishes-page.tsx:98-111` 现状（关键三段）：

```tsx
	// 跨页开场记忆（KTD8）：voices ∥ wishes 任一标记即视为已看。
	const introSeen = useSyncExternalStore(
		() => () => {},
		() => { /* 读 localStorage 两个 key，返回 Boolean */ },
		() => null,   // ← 服务端快照恒 null
	);
	...
	if (introSeen === null) return null;   // ← SSR 与水合前整页为空

	return (
		<WishesWall
			initialItem={direct ?? undefined}
			initialCity={initialCity}
			showIntro={!direct && !introSeen}
		/>
	);
```

`wishes-wall.tsx:135-138` —— `showIntro` 的全部消费（墙内没有任何开场动画/遮罩）：

```tsx
	useEffect(() => {
		if (showIntro) markIntroSeen();
	}, [showIntro, markIntroSeen]);
```

行为等价性（为什么删掉守卫是安全的）：现状下，没看过开场的用户水合后 `introSeen === false` → `showIntro = true` → 挂载 effect 立即写标记。删除守卫后，SSR/水合前 `introSeen === null` → `!introSeen` 同样为 `true` → 同一 effect 做同一件事。对「已看过」的老用户（`introSeen === true`）两版都是 `showIntro = false`。唯一变化：墙的 header/文案/骨架提前到 HTML 里。

`?item=` 直达路径不受影响：`item` 存在且校验未完成时 `direct === undefined`，既有加载壳分支（`if (item && direct === undefined)`）先于 return 执行，保持原样。

本仓库约定：tab 缩进；注释用中文，沿用领域词（纸签 / 挂树 / 期待 / 附议 / 开场）；i18n 文案在 `web/messages/zh-CN.json` 与 `web/messages/en.json` 双语言同步（CI `scripts/check-i18n-keys.mjs` 强制 100% 覆盖）。本计划不需要新增文案。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0，无输出 |
| 单测（wishes） | `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` | 全部 pass |
| lint | `cd web && npx eslint "app/[locale]/flashback/wishes"` | 0 errors |
| SSR 冒烟 | Step 3 探测 +「一抓一剥三断言」（先 curl 落临时文件 → `sed` 剥 `<script>` → 三 grep） | 修复前全 0；修复后『换一批』≥1、`<(header|aside)[ >]` ≥2、『正在挂愿望』≥1。dev server 没跑就自己拉起，不允许跳过 |

## Scope

**In scope** (the only files you should modify):
- `web/app/[locale]/flashback/wishes/wishes-page.tsx`
- `web/app/[locale]/flashback/wishes/wishes-page.test.tsx`（新建）

**Out of scope** (do NOT touch, even though they look related):
- `web/app/[locale]/flashback/voices/` 下的任何文件——voices 有真实开场动画，`return null` 守卫在那边是有意义的，不要「顺手统一」。
- `wishes-wall.tsx`——它的 `showIntro` 行为保持不变。
- **任何形式的愿望列表服务端预取**（`page.tsx` fetch、RSC 改造、`fetchPolicy` 调整、Apollo SSR 边界）——愿望数据保持客户端 `useEffect` 拉取，这是产品架构不是缺陷。
- 后端任何文件。

## Git workflow

- Branch: 在当前 worktree 分支上继续即可（`codex-improve-wish2UI`）。
- Commit style（照 repo 现状）：`fix(flashback): wishes page renders via SSR — drop introSeen gate`
- 只在本地 commit；**不要 push、不要开 PR**（worktree SOP：push/PR 归编排者）。

## Steps

### Step 1: 删除 `introSeen === null` 的整页空渲染守卫

在 `wishes-page.tsx` 中删除这一行及其上方的空行：

```tsx
	if (introSeen === null) return null;
```

并在删除处补一行中文注释，说明为什么不拦（给未来读者）：

```tsx
	// introSeen === null（SSR/水合前）不拦渲染：墙无开场动画，showIntro 仅写
	// 「已看」标记（KTD8），提前渲染只赚 SSR 与首屏（voices 有开场才需要拦）。
```

`return <WishesWall ... />` 的 JSX 与 `showIntro={!direct && !introSeen}` 计算保持不变。

**Verify**: `cd web && npx tsc --noEmit` → exit 0。

### Step 2: SSR HTML 断言（本计划的真红绿测试）+ 轻量客户端回归

**先做红绿基准**：在执行 Step 1 之前，先跑 Step 3 的 SSR 冒烟命令（dev server 就绪后）确认它在修复前**红**——修复前渲染正文是 `<div hidden=""></div><div></div>`，剥掉 `<script>` 后没有任何 header/aside/正文文案；三条断言全 0。Step 1 之后再跑确认**绿**。只有这样才能证明测试真的钉住了 SSR 正文，而不是 RSC flight payload 里的同名字符串。

**坑（执行期告警）**：裸 `curl … | grep -c '换一批'` 在修复前也会返回 1——Next 的 RSC flight payload 内嵌在 `<script>` 标签里，包含组件树序列化的文案字符串。所以 **grep 前必须先剥 `<script>`**，否则红绿全是假信号。

mock 方式照抄 `wishes-wall.test.tsx` 的既有结构（同目录，先读它）：`vi.mock("@/lib/apollo-client")` 里按 `FLASHBACK_PUBLIC_WISHES` / `FLASHBACK_CITIES` 分发（WishesWall 挂载后两个 query 都会发），默认返回空数组数据。`vi.mock("@apollo/client/react")` 照抄同文件的 useMutation mock。

**核心测试是 Step 3 的 SSR 冒烟**（non-jsdom、走真实 dev server，一抓一剥三断言）：抓 HTML → `sed` 剥 `<script>` → 三 grep。这不是 vitest 能替代的（jsdom 无 SSR）。

vitest 这一侧只补两条**轻量客户端回归**（它们不是红绿闸门，只是防其他代码路径误伤）：

1. **WishesPage mount 后展示墙（回归基线）**：`render(<WishesPage initialItem={undefined} initialCity={undefined} showIntro={false} />)` 后 `await screen.findByText("换一批")`。修复前后都会绿——它不是红绿点，只是「没打破 mount 链路」的护栏。
2. **开场标记仍被写入（KTD8 行为不回退）**：`render(<WishesPage initialItem={undefined} initialCity={undefined} showIntro={true} />)` 后 `await waitFor(() => expect(window.localStorage.getItem("flashback.wishesIntroSeen")).toBe("1"))`。

`wishes-wall.test.tsx` 既有用例照此改：`showIntro={false}` 显式传（它们当前隐式走默认 `false`,把默认值显式化不影响断言）。

文案值先在 `web/messages/zh-CN.json` 的 `flashback.wishes` 命名空间确认（`shuffle`、`writeWish` 等 key），测试里用 zh 值（test-utils 默认 locale）。

**Verify**: `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` → 全部 pass，含新文件；既有 `wishes-wall.test.tsx` 6 条不回归。

### Step 3: SSR 冒烟（本计划的红绿闸门）

先探测 dev server：

```
curl -sS -o /dev/null -w '%{http_code}' http://localhost:3996/flashback/wishes
```

- 输出 `200` → 直接走下一条 curl。
- 输出非 200 / 连接被拒 → `cd web && pnpm dev --port 3996` 后台拉起，循环 `curl` 直到 200（最多 60s）再走下一条。

断言（一抓一剥三 grep——先抓一份 HTML 落临时文件，剥 `<script>` 后三次 grep；`<script>` 剥除是必须的，见 Step 2 告警）：

```
HTML=/tmp/wishes-ssr.html
curl -s http://localhost:3996/flashback/wishes > "$HTML"
# 剥 script：`</script>` 可能跨行（payload 里的 \n），用 tr 压行后剥
tr '\n' '\0' < "$HTML" | sed -E 's|<script[^>]*>.*</script>||g' | tr '\0' '\n' > /tmp/wishes-body.html

# 修复前期望全 0（正文 <div hidden=""></div><div></div>）；修复后：
grep -c '换一批'     /tmp/wishes-body.html    # ≥1
grep -Eo '<(header|aside)[ >]' /tmp/wishes-body.html | wc -l   # ≥2（-o 逐标签计数；\b 在 BSD grep -E 下不可靠，用 [ >] 菱形边界）
grep -c '正在挂愿望' /tmp/wishes-body.html    # ≥1（面板加载壳 SSR 输出——「正在挂愿望…」才是 flashback.wishes.loading 的实际值；「加载中…」属于 initiatives 等 12 个其它 namespace，wishes SSR HTML 里没有）
```

**Verify**: 三条命令各自返回期望值；把三条输出原样粘贴进完成报告作为证据。若第二条输出 0 → 正文里没有结构化 shell，说明删守卫没生效，回 Step 1。

## Test plan

- 新文件 `wishes-page.test.tsx`：上述两条用例（不 return null 的回归 + 开场标记写入）。
- 结构模式照 `web/app/[locale]/flashback/wishes/wishes-wall.test.tsx`（同目录、同 mock 手法）。
- 验证：`cd web && pnpm vitest run "app/[locale]/flashback/wishes"` → 全 pass。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && pnpm vitest run "app/[locale]/flashback/wishes"` 全 pass，含新建 `wishes-page.test.tsx` ≥2 条
- [ ] `grep -n "introSeen === null" "web/app/[locale]/flashback/wishes/wishes-page.tsx"` 无匹配
- [ ] SSR 一抓一剥三断言全绿（Step 3 命令，修复前全 0 / 修复后 见 Commands 表期望值）
- [ ] `git status` 显示只有 in-scope 两个文件被改（加 README = 三个条目）
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- `wishes-page.tsx` 现状与「Current state」摘录不符（已漂移）。
- 删除守卫后 wishes 相关既有测试出现 hydration/act 警告且两轮修复无效。
- 你发现 `WishesWall` 实际上存在开场动画逻辑（与本计划的前提矛盾）——说明代码已变，停下来报告。

## Maintenance notes

- 若将来给 wishes 墙也加开场动画（产品决策），需要恢复一个「首帧不渲染动画区」的守卫——届时改为在墙内部拦动画而非整页 `return null`，保住 SSR。
- reviewer 重点看：删除守卫后 `?item=` 失效视图（`direct === "gone"`）与加载壳分支的先后顺序未被破坏。
