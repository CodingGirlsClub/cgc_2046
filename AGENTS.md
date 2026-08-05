## Agent principles

- **Don't preserve backward compatibility.** Delete obsolete code paths instead of adding compatibility layers, fallbacks, or migration code.
- **Choose the simplest implementation** that fully meets current needs. Avoid speculative abstractions, configuration, and indirection.
- **Build systems in layers.** Start with the smallest version that runs end-to-end, add new features on top of an already working product. Never trade a working product for unfinished complexity.
- **Keep components modular** with clear separation of concerns.
- **Prefer mature, well-maintained libraries** when they reduce overall complexity or improve reliability. Don't reimplement common functionality without good reason.
- **Leverage existing dependencies** in the project before writing your own implementation or adding new packages. Don't assume a library lacks a capability without consulting its documentation and types.
- **License compliance is a hard gate for new dependencies.** Any Hex/npm/native dependency you introduce must be AGPL-3.0-compatible: permissive licenses (MIT/Apache-2.0/BSD/ISC/0BSD/CC0) or AGPL-compatible weak copyleft (MPL-2.0/LGPL-3.0+/EPL-2.0). **Forbidden:** GPL-2.0-only, SSPL, BUSL, Elastic, proprietary, unlicensed. Multi-license declarations are OK only if at least one allowed option exists. When unsure, open an issue instead of adding the dependency. Rules: `docs/开源合规/依赖引入规则.md`; CI enforces via `mix cgc2046.check_licenses` + `pnpm check:licenses`.
- **Make long-term architectural decisions.** Don't accept temporary solutions that only work now with the intention of replacing them later.
- **Study how established products solve the problem** before designing a solution. Adopt their proven patterns and conventions rather than inventing an approach from scratch.

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues in `CodingGirlsClub/cgc_2046`, driven via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root plus `docs/adr/` for architecture decisions. See `docs/agents/domain.md`.
