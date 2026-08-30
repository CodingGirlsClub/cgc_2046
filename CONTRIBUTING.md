# Contributing to CGC Platform

Thanks for taking the time to contribute. Every PR will be reviewed. We evaluate each contribution along three dimensions:

1. **Value of the need** — is this useful, and to whom?
2. **Architectural impact** — does it fit the existing design?
3. **Code standards** — does it meet our quality bar?

Read the sections below before opening a PR. If your contribution clearly delivers outsized value, the rules here can bend — see [Exceptions](#exceptions).

---

## 1. Read the Docs First — Domain Discipline

This project is **documentation-driven**. Before writing code, read:

- **[CONTEXT.md](./CONTEXT.md)** — the **single source of truth for domain terminology**. All code, docs, issues, tests, and commit messages must use exactly these terms. Do not introduce synonyms. If you believe a term is missing, propose it separately and get it added to CONTEXT.md first.
- **[docs/00-CGC平台设计总纲.md](./docs/00-CGC平台设计总纲.md)** — single source of truth for core design decisions. In case of conflict with other docs, the finalized docs in `docs/01-定稿设计/` win.
- **[docs/adr/](./docs/adr/)** — Architecture Decision Records. Significant architectural choices go through an ADR, not just a PR.

## 2. Architecture First

Improvements built on top of the existing, stable architecture are accepted quickly. The project's operating principles (see `AGENTS.md`) are:

- **Don't preserve backward compatibility.** Delete obsolete code paths instead of adding compatibility layers, fallbacks, or migration code.
- **Choose the simplest implementation** that fully meets current needs. No speculative abstractions, configuration, or indirection.
- **Build systems in layers** — a small version running end-to-end beats unfinished complexity.
- **Leverage existing dependencies** before adding new ones or writing your own implementation.

A change that "fits" means: the **smallest possible diff**, **no new configuration knobs** unless strictly required, **no new dependencies** unless strictly required (see §6), and it **respects existing layering, abstractions, and naming conventions** — including the established Ash resource patterns (attribute multitenancy, policies, GraphQL exposure) and frontend conventions (typed GraphQL contracts via `TypedDocumentNode`, dual dark/light theme).

PRs that introduce parallel mechanisms, speculative abstractions, or "just in case" flexibility will be sent back for trimming.

## 3. Issue-Driven Workflow

- Work is tracked as GitHub issues in `CodingGirlsClub/cgc_2046`, developed in vertical **slices** (each slice is a set of issues, e.g. join governance).
- Issues carry canonical triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.
- Claim an issue before starting (assign yourself / say so in a comment), then create a branch named after the slice, e.g. `feature/slice-B`.
- Reference the issue in the PR (`Closes #N`).
- Development is test-first: write the test that defines the success criteria, then implement until it passes.

## 4. Code Standards

### Backend (Elixir / Phoenix / Ash)

The CI pipeline runs in `backend/`:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix cgc2046.gen_rbac_contract --check   # RBAC capability/policy contract must not drift
mix test
```

Conventions:

- Always `mix format` before committing; `.formatter.exs` covers `lib`, `test`, and `priv/*/migrations`.
- New Ash resources follow the existing templates: attribute multitenancy (`workspace_id`), `Ash.Policy.Authorizer` policies, AshGraphql exposure via the domain, and registration in its bounded-context domain (`Cgc2046.Accounts` / `Admission` / `Events` / `Courses` / …；领域地图见 CONTEXT.md——`GlobalApi` 已退役为 `Accounts`).
- New Oban workers / Ash changes follow the ownership mapping in `docs/adr/0010-workers-changes-directory-closure.md`(worker 归其状态机属主域;change 归其消费/数据属主域——根部不再有 workers/、changes/ 收容层)。
- Migrations must be **idempotent** (`table_exists?` / `index_exists?` / `column_exists?` guards) and reversible (`down` drops).
- Never store bearer credentials (tokens, secrets) in plaintext columns. Token-hash or return-once via metadata, following the existing `Invitation`/`TokenResource` patterns.
- New endpoints/actions keep the GraphQL schema contract in sync — the frontend contracts live in `web/lib/graphql/*.ts`.

### Frontend (Next.js / TypeScript)

The CI pipeline runs in `web/`:

```bash
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
pnpm build
```

Conventions:

- GraphQL access goes through typed contracts in `web/lib/graphql/*.ts` (`TypedDocumentNode`), consumed via mapping functions in `web/lib/*.ts` with pure-function unit tests (mirror the `workspaces.ts` pattern).
- Next.js 16: any page using `useSearchParams` must be wrapped in `Suspense` (CSR bailout).
- All pages and components must render correctly in both light and dark themes.

### Tests

- All tests **must pass** before a PR can be merged.
- **Coverage must not drop.** New code needs new tests — backend resource/action tests and frontend mapping-function tests are mandatory for new behavior.

## 5. Commits & PRs

- **Commit messages and PR titles/descriptions may be written in Chinese or English.** Keep conventional-commit type prefixes (`feat`/`fix`/`docs`/...) and technical terms in English either way. (Issue bodies and code comments may stay in Chinese.)
- Keep commits focused; squash noise before requesting review.
- PR descriptions should briefly state: **what**, **why**, and any **user-visible impact** (e.g. new routes, changed permissions).
- Run the full gate matrix before pushing: `mix test` + `pnpm test` + `pnpm typecheck` + `pnpm lint` + `pnpm build`.

## 6. Dependencies

- **Avoid adding new libraries.** Prefer the standard library, existing dependencies, or a few lines of code over pulling in another package.
- If a new dependency is genuinely necessary, justify it in the PR description: why this library, why not write it ourselves, its license, and maintenance status.
- **License compliance is mandatory:** every new dependency (direct or transitive) must be AGPL-3.0-compatible per [docs/开源合规/依赖引入规则.md](./docs/开源合规/依赖引入规则.md). GPL-2.0, SSPL, BUSL, Elastic, proprietary, and unlicensed packages are forbidden — CI enforces this via `mix cgc2046.check_licenses` + `pnpm check:licenses`.
- Keep `pnpm-lock.yaml` / `mix.lock` up to date with the actual dependency change.

## 7. Exceptions

Rules exist to keep the project healthy, not to block valuable work. For contributions that deliver **substantial, clear value**, the standards above can be relaxed at the maintainers' discretion. When in doubt, open an issue or draft PR first to discuss the trade-offs.

## 8. License

This project is licensed under the **GNU Affero General Public License v3.0** ([LICENSE](./LICENSE)). By contributing, you agree that your contribution is licensed under the same terms — including the AGPL's network-use copyleft provisions.
