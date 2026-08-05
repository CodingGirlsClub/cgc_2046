<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## License gate for new npm dependencies

Any npm package you add must be AGPL-3.0-compatible: permissive (MIT/Apache-2.0/BSD/ISC/0BSD/CC0) or weak copyleft (MPL-2.0/LGPL-3.0+/EPL-2.0). **Forbidden:** GPL-2.0, SSPL, BUSL, Elastic, proprietary, unlicensed. CI runs `pnpm check:licenses`; when unsure, open an issue first (see `docs/开源合规/依赖引入规则.md`).

# GraphQL 契约层架构约定

契约层（`web/lib/graphql/`）按领域分文件，对齐数据源层（`requests.ts` / `invitations.ts`）：

- `join-request.ts` — JoinRequest 相关 mutation/query（含 `JOIN_WORKSPACE`，`requests.ts` 是唯一消费方）
- `invitation.ts` — Invitation 相关 mutation/query
- `shared.ts` — 跨领域的共享类型单源：`MutationError` interface + `MutationResult<T>` 包装类型

勿在各领域文件本地重定义 `MutationError` / `MutationResult`——一律 `import` 自 `graphql/shared.ts`。
