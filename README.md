# CGC Platform

> Multi-tenant community collaboration platform for **Coding Girls Club** — workspaces, roles & RBAC, join governance (applications / invitations), and a workflow engine for enrollment, sponsorship, speaker invitations, and teaching research.

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

## Architecture in one sentence

**The website is a business hub + MCP server; users bring their own OpenClacky as the agent executor (BYO).** The platform runs no LLM inference — it owns business state, authorization, and audit; all AI execution happens in the user's local OpenClacky via MCP. Business orchestration is deterministic, driven by a Jido workflow engine (workflow-first).

## Tech stack

| Layer | Stack |
| ------- | ------- |
| Backend | Elixir 1.20 / Phoenix / Ash Framework (AshGraphql, AshPolicy, ash_authentication) / PostgreSQL 16+ |
| Frontend | Next.js 16 / React 19 / TypeScript / Apollo Client 4 / Tailwind CSS v4 / Vitest |
| Workflow | Jido ecosystem (jido, jido_runic, ash_jido) |

## Getting started

### Backend (`backend/`)

```bash
cd backend
mix setup   # deps.get + ecto.create/migrate + seeds（默认工作台 2046 + 角色 + 协议定义）
mix phx.server
```

> 种子必跑：没有默认工作台 `2046` 时，新用户注册会静默降级不入座（注册成功但
> 所有工作台面为空、无报错指向缺种子）。

Gates (also enforced in CI, see `.github/workflows/ci.yml` backend job):

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix cgc2046.gen_rbac_contract --check
mix cgc2046.gen_error_codes_contract --check
mix cgc2046.check_licenses
mix ash_postgres.generate_migrations --check
mix hex.audit
mix test
```

### Frontend (`web/`)

```bash
cd web
pnpm install
pnpm dev
```

Gates (also enforced in CI):

```bash
pnpm typecheck
pnpm lint
pnpm test
pnpm build
```

## Documentation

- **[CONTEXT.md](./CONTEXT.md)** — single source of truth for domain terminology (all code, docs, issues, and tests must use exactly these terms)
- **[DESIGN.md](./DESIGN.md)** — design overview
- **[docs/adr/](./docs/adr/)** — Architecture Decision Records (why, including rejected options)
- **[docs/agents/](./docs/agents/)** — agent workflow conventions (issue tracker, triage labels, domain docs)
- **[docs/开源合规/](./docs/开源合规/)** — dependency license rules (AGPL-3.0 compatibility, CI-enforced)

## Development workflow

We develop in vertical **slices** (e.g. slice A: auth/workspace/RBAC; slice B: join governance), each driven by a set of GitHub issues. See [CONTRIBUTING.md](./CONTRIBUTING.md) for how to contribute.

## License

AGPL-3.0 — see [LICENSE](./LICENSE). Contributions are accepted under the same terms.
