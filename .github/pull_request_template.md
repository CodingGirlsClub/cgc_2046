## What

<!-- Briefly: what does this PR change? -->

## Why

<!-- Briefly: why is this needed? Reference issues with Closes #N. -->

## User-visible impact

<!-- New routes, changed permissions, UI changes, etc. If none, say "None." -->

## Checklist

- [ ] Tests pass: `mix test` (backend) + `pnpm test` (web)
- [ ] `pnpm typecheck` + `pnpm lint` + `pnpm build` pass (web changes only)
- [ ] `mix format --check-formatted` + `mix compile --warnings-as-errors` pass (backend changes only)
- [ ] Added dependencies? Confirmed license is AGPL-3.0-compatible per [docs/开源合规/依赖引入规则.md](docs/开源合规/依赖引入规则.md) (CI checks: `mix cgc2046.check_licenses` / `pnpm check:licenses`)
- [ ] New domain concepts use terminology from [CONTEXT.md](CONTEXT.md) (no synonyms)
