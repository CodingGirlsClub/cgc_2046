<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## GraphQL 契约层架构约定

契约层（`web/lib/graphql/`）按领域一个文件（`orders.ts`、`flashback.ts`……）。跨领域共享类型单源在 `graphql/shared.ts`（`MutationError` interface + `MutationResult<T>`）——各领域文件一律从这里 `import`，不本地重定义。

## 前端测试执行约定

跑 web 端测试统一在 `web/` 目录内执行 `pnpm vitest`（走 `web/vitest.config.mts`，缓存落在 `web/node_modules/.vite`）。不要在仓库根目录用 `npx vitest run web/...` 裸调——那会把 project root 当成仓库根，vitest 缓存误写入根目录 `node_modules/.vite`（根目录不应有 node_modules，见根 `.gitignore`）。

- **日期/时间断言禁止写死本地时区偏移**：CI runner 跑 UTC、开发机常是 UTC+8，写死 `18:00`（fixture `…T10:00:00Z` 在 UTC+8 的呈现）在 CI 必红。做法：期望值用被测格式化函数现场算（`new Date(x).toLocaleString(...)`、`formatDateTime(fixture)`），或只断言时区无关形状；改动后用 `TZ=UTC pnpm vitest <file>` 与 `TZ=Asia/Shanghai pnpm vitest <file>` 双向自证。

## E2E 验证（ego-browser）

UI 改动后，Dev 服务跑起来，用 ego-browser 做端到端验证。按确定性分层，能数值断言的不问模型：

1. **结构 / 样式断言（主，确定性最高）**：`page.evaluate()` 拿 computed style（`getComputedStyle`）与几何（`getBoundingClientRect`），断言具体数值——宽度 / 背景色 / 圆角 / 边距 / 选中态类名与边框 / 对齐差（<1px）。渲染差异、组件回归、多页一致性都用这一层判定，不需要视觉模型。
2. **交互走通**：`page.snapshot()`（refs）→ `page.click("@N")` / `page.fill()` → `page.waitForURL()` / `page.waitForSelector()` / `page.waitForFunction()`，断言导航与状态变化（错误分支、成功分支都走）。
3. **视觉复核（兜底，仅感知层）**：`page.screenshot()` 截图交给视觉模型，只查无法数值断言的主观项——层级 / 对比度观感 / 留白协调 / 整体美感；截图同时作为给人看的证据。截图前先确认结构断言已全部通过，不要每个页面都截图问模型。
4. **登录态**：ego-browser（ego-lite）即用户日常浏览器，默认复用其已登录 profile；确需独立登录态时，先备份 `users.hashed_password`（psql 连当前 checkout 的 dev 库——worktree 里是 `cgc_2046_dev_<slug>`，规则见 `backend/AGENTS.md`），临时重置密码完成验证后**必须恢复原哈希**。
