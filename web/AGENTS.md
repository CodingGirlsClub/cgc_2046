<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## License gate for new npm dependencies

Same rule as the root `AGENTS.md` license gate (source of truth: `docs/开源合规/依赖引入规则.md`); CI runs `pnpm check:licenses`.

# GraphQL 契约层架构约定

契约层（`web/lib/graphql/`）按领域分文件，对齐数据源层（`requests.ts` / `invitations.ts`）：

- `join-request.ts` — JoinRequest 相关 mutation/query（含 `JOIN_WORKSPACE`，`requests.ts` 是唯一消费方）
- `invitation.ts` — Invitation 相关 mutation/query
- `shared.ts` — 跨领域的共享类型单源：`MutationError` interface + `MutationResult<T>` 包装类型

勿在各领域文件本地重定义 `MutationError` / `MutationResult`——一律 `import` 自 `graphql/shared.ts`。

# 前端测试执行约定

跑 web 端测试统一在 `web/` 目录内执行 `pnpm vitest`（走 `web/vitest.config.mts`，缓存落在 `web/node_modules/.vite`）。不要在仓库根目录用 `npx vitest run web/...` 裸调——那会把 project root 当成仓库根，vitest 缓存误写入根目录 `node_modules/.vite`（根目录不应有 node_modules，见根 `.gitignore`）。

- **日期/时间断言禁止写死本地时区偏移**：CI runner 跑 UTC、开发机常是 UTC+8，写死 `18:00`（fixture `…T10:00:00Z` 在 UTC+8 的呈现）在 CI 必红。做法：期望值用被测格式化函数现场算（`new Date(x).toLocaleString(...)`、`formatDateTime(fixture)`），或只断言时区无关形状；改动后用 `TZ=UTC pnpm vitest <file>` 与 `TZ=Asia/Shanghai pnpm vitest <file>` 双向自证。
- **新增守卫/断言必须做变异验证**：临时改坏被守卫的实现（或删掉守卫本身）时对应断言必须变红——只"绿"不算钉住（假绿常见于断言落在空集合/被跳过的分支上）。做法：先改坏、确认红，再还原、确认绿，两步输出都留在同一会话里。
