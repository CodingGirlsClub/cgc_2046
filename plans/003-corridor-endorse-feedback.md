# Plan 003: capsule 长廊附议失败可见化——token-only 用户不再点了没反应

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 6cd74306..HEAD -- web/components/flashback/wish-frames.tsx web/components/flashback/corridor.test.tsx`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: none（004/005 同文件，建议本计划先行）
- **Category**: bug（KTD3 后端改造的前端遗漏）
- **Planned at**: commit `6cd74306`, 2026-09-23

## Why this matters

wish2 生产批（KTD3）把附议改造为**登录承诺动作**：后端 `flashbackEndorseWish` 已删除 token 匿名腿，未登录调用统一返回业务错误码 `flashback_auth_required`（`graphql_schema.ex:3051-3066`，`with_actor(..., on_nil: ...)`）。设计文档同步拍板「token-only 用户在附议表单处走登录引导」，但该引导只在**小程序端（U9）落地**；Web 端 capsule 长廊（`/flashback/capsule`，校友凭专属 token 链接进入的成员面）的附议按钮仍在，而它的统一错误处理是**静默吞掉**：

```tsx
	} catch {
		// 失败静默：下一帧 reload 校正
	}
```

对 token-only 用户（无站点会话，capsule 的主要访客形态）而言，点「附议」→ 后端拒绝 → 前端零反馈。这不是理论路径：capsule-view 的 token 从 URL 读入存 sessionStorage（`capsule-view.tsx:18-50`），这类用户没有会话 actor。

本计划做**最小可见化**：失败时显示服务端业务错误文案（`errors.flashback_auth_required` 已有双语文案）。不做登录回跳链路（涉及 returnUrl 编排，超范围；附议主路径已由小程序承接）。

## Current state

- `web/components/flashback/wish-frames.tsx` — corridor 愿望卡/模态/表单组件族；`WishFrames` 是长廊公开愿望段的容器。
- `web/components/flashback/future-frames.test.tsx` — WishFrames/WishFormModal 的既有测试宿主（import Corridor、useMutationMock、capsule fixture、「机审拒绝」code 拒绝先例都在这里；corridor.test.tsx 只测 pile 聚合——原计划写它是笔误，执行期纠正）。
- `web/lib/graphql/auth.ts:280` — `graphqlErrorDetails(e)`：从 GraphQL 错误提取 `{ code, ... }`，`wish-frames.tsx` 已 import（`WishFormModal` 在用）。
- `web/lib/payment-errors.ts:28` — `usePaymentErrorTranslator()`：`(code, fallback) => 文案`，已知 code 查 `messages/*.json` 的 `errors` 命名空间。

`wish-frames.tsx:57-71` 现状（`WishFrames` 内）：

```tsx
	const [endorse] = useMutation(FLASHBACK_ENDORSE_WISH);
	const [comment] = useMutation(FLASHBACK_ADD_WISH_COMMENT);
	const [deleteWish] = useMutation(FLASHBACK_DELETE_WISH);

	const run = async (fn: () => Promise<unknown>) => {
		if (busy) return;
		setBusy(true);
		try {
			await fn();
			onChanged();
		} catch {
			// 失败静默：下一帧 reload 校正
		} finally {
			setBusy(false);
		}
	};
```

附议按钮（`:115-122`，公开愿望卡内）与 `WishModal` 内的附议按钮（`:394-402` 附近）都经 `run()` 走 `endorse`。

后端契约（`graphql_schema.ex:3042-3066`，只读参考，不改后端）：`flashbackEndorseWish` 要求登录，未登录返回：

```elixir
{:error, [message: "请先登录后再附议。", code: "flashback_auth_required"]}
```

文案（已存在，勿新增）：`web/messages/zh-CN.json` → `errors.flashback_auth_required` = 「进入时间长廊需要你的专属链接，或登录已绑定的账号。」；en 同 key 已有。

样式约定：错误行用 `fb-hint` class（仓库既有，`flashback.css` 全局定义，`WishFormModal` 错误行同款）。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 类型检查 | `cd web && npx tsc --noEmit` | exit 0 |
| 单测 | `cd web && pnpm vitest run components/flashback` | 全部 pass |
| lint | `cd web && npx eslint components/flashback/wish-frames.tsx` | 0 errors |

## Scope

**In scope**:
- `web/components/flashback/wish-frames.tsx`（仅 `WishFrames` 组件；`WishFormModal`/`WishModal` 的表单错误处理是 004/005 的地盘，本计划不碰）
- `web/components/flashback/future-frames.test.tsx`（追加用例）

**Out of scope**:
- 后端任何文件——`flashback_auth_required` 契约已存在。
- 登录回跳/深链编排（`returnUrl` 链路）——超范围，见 Maintenance notes。
- `WishFormModal` 与 `WishModal` 内部的错误处理。
- 小程序端。

## Git workflow

- 当前 worktree 分支继续；commit style：`fix(flashback): surface endorse auth error in corridor wish frames`
- 只本地 commit，不 push。

## Steps

### Step 1: `run()` 捕获业务错误码并透出

在 `WishFrames` 组件内：

1. 新增状态与文案 hook（组件顶部，紧邻现有 hooks）：

```tsx
	const tErrors = useTranslations("errors");
	const errorT = usePaymentErrorTranslator();
	const [actionError, setActionError] = useState<string | null>(null);
```

import 状态：仓库 `web/components/flashback/wish-frames.tsx:8-9` **已 import** `graphqlErrorDetails` 与 `usePaymentErrorTranslator`——不要补第二次（会触发 ESLint `import/no-duplicates`）；**但是** `useTranslations("errors")` 这个 namespace hook 需要新加，因为组件里目前只有 `useTranslations("flashback.wish")`（`:41`）。只加 `useTranslations("errors")` 的本地变量声明，不动 import 区。

2. 改 `run()`：

```tsx
	const run = async (fn: () => Promise<unknown>) => {
		if (busy) return;
		setBusy(true);
		try {
			await fn();
			setActionError(null);
			onChanged();
		} catch (e) {
			// 失败可见化（KTD3：token 腿下线后 auth_required 是常态路径，静默=按钮假死）；
			// 已知业务码取 errors 文案，未知码兜底 database_error
			const code = graphqlErrorDetails(e)?.code;
			setActionError(errorT(code, tErrors("database_error")));
		} finally {
			setBusy(false);
		}
	};
```

先确认 `errors.database_error` key 存在于两个 messages 文件（`WishFormModal` 已把它当兜底，应当存在）。

3. 展示位：`WishFrames` 返回 JSX 的公开愿望段 `<article className="fb-corridor-frame fb-future-frame">` 内、`<ul className="fb-wish-list">` 之后加：

```tsx
				{actionError && (
					<p role="alert" className="fb-hint">
						{actionError}
					</p>
				)}
```

**Verify**: `cd web && npx tsc --noEmit` → exit 0。

### Step 2: 追加回归测试

`future-frames.test.tsx` 已有 `useMutationMock` + capsule fixture + fireEvent 全套基础设施（「机审拒绝」`:277-290` 是 code 拒绝直接先例；「listed 反馈」`:295-306` 是 mock.calls 末击判别 doc 手法）。用 `useMutationMock.mockReturnValue`（或按 doc 判别 `FLASHBACK_ENDORSE_WISH`）让 endorse reject。

愿望卡定位照抄 `wishes-wall.test.tsx:75-78` 的「`screen.findByText(内容)` → `closest("article")` → `within(card)`」三段式（corridor 愿望段内同文按钮不止一个，裸 `getAllByRole` 会撞 WishModal 的同名按钮）：

用例：附议失败显示服务端文案——渲染带一条公开愿望的 `Corridor`，让 endorse mutation reject `{errors: [{message: "no auth", extensions: {code: "flashback_auth_required"}}]}`（形状见上），`within(card).getByRole("button", { name: /附议/ })` 点击，**断言只能有一条，不许「或」**（「或」会把 code-path 断言降级为「alert 存在」的伪断言）：

- `expect(await screen.findByRole("alert")).toHaveTextContent("进入时间长廊需要你的专属链接，或登录已绑定的账号。")`——用 zh locale 下 `errors.flashback_auth_required` 的**完整串**（`web/messages/zh-CN.json` grep 实际值后原样写入断言，不要截断不要省略）。
- busy 结束后按钮恢复可用（不卡死）。

**Verify**: `cd web && pnpm vitest run components/flashback` → 全 pass；red→green 证据写进报告。

**错误形状（钉死，照抄 `future-frames.test.tsx:280-283`）**：`graphqlErrorDetails`（`web/lib/graphql/auth.ts:280-303`）从 Apollo 抛出的 error 对象的**顶层 `errors[]` 或 `graphQLErrors[]` 第 0 个**读 `extensions.code`——没有 `CombinedGraphQLErrors` 这个类参与（那是过时的 Apollo v3 概念，**不要 import**）。测试注入用 `mockRejectedValue({errors: [{message: "...", extensions: {code: "..."}}]})` 形状即可，已验证路径。

## Test plan

- 新用例 1 条：token-only 附议失败 → `role="alert"` 可见业务文案。
- 既有 corridor / future-frames 测试不许回归。

## Done criteria

- [ ] `cd web && npx tsc --noEmit` exit 0
- [ ] `cd web && pnpm vitest run components/flashback` 全 pass
- [ ] `grep -n "失败静默" web/components/flashback/wish-frames.tsx` 无匹配（旧注释消失）
- [ ] `git status` 只有 in-scope 两文件
- [ ] `plans/README.md` 状态行更新

## STOP conditions

- `wish-frames.tsx` 的 `run()` 与摘录不符（已被 004/005 或他人改动）——与执行者协调合并，不要覆盖。
- `graphqlErrorDetails` 无法从测试注入的错误形状中提取 code（提取逻辑对 Apollo 错误类的耦合比预期深）——报告实际形状，不要改 `graphqlErrorDetails` 本身。
- 你发现 corridor 的附议按钮已被移除或该组件已下线——报告即可，本计划自然失效。

## Maintenance notes

- 后续若做 Web 端登录回跳（`flashback_auth_required` → 跳 `/flashback/enter` 带 returnUrl），把这个 `<p role="alert">` 升级为带链接的引导块即可，状态与捕获链路可复用。
- reviewer 重点看：`run()` 成功路径 `setActionError(null)` 的位置在 `onChanged()` 之前（避免 reload 抛错时误清错误提示）。
