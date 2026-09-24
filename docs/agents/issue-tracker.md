# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues in `CodingGirlsClub/cgc_2046`. Run every operation through `gh-axi` (`npx -y gh-axi` when it isn't on PATH), never raw `gh`. Its flags are not `gh`'s: there is no `--json`/`--jq` (unknown flags are silently ignored), `issue list` takes `--fields`, and `api` takes the method positionally plus `--field`.

## Conventions

- **Create an issue**: `gh-axi issue create --title "..." --body-file <path>`. Write multi-line bodies to a file first.
- **Read an issue**: `gh-axi issue view <number> --comments --full`. It doesn't print labels; get them from `gh-axi api /repos/<owner>/<repo>/issues/<number>`.
- **List issues**: `gh-axi issue list --state open --label <name> --fields body,labels` (comments aren't available here; read them with `issue view`).
- **Comment on an issue**: `gh-axi issue comment <number> --body "..."` (or `--body-file <path>`)
- **Apply / remove labels**: `gh-axi issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh-axi issue close <number> --comment "..."` (add `--reason not_planned` when it won't be done)

`gh-axi` infers the repo from the clone's remote; pass `-R owner/name` otherwise.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

GitHub shares one number space across issues and PRs, so a bare `#42` may be either — resolve with `gh-axi pr view 42` and fall back to `gh-axi issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh-axi issue view <number> --comments --full`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh-axi issue create --title "..." --label wayfinder:map --body-file <path>`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh-axi issue subissue add <map> <child>`). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies** — the canonical, UI-visible representation. Add an edge with `gh-axi api POST /repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by --field issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (the `id` field of `gh-axi api /repos/<owner>/<repo>/issues/<n>`, _not_ the `#number`). List a ticket's blockers with `gh-axi api /repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by` — the live gate; `gh-axi` strips `issue_dependencies_summary` from issue payloads, so don't look for it there. Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's children (`gh-axi issue subissue list <map>`, or the map body's task list) and keep the open ones; drop any with an open blocker (an open issue in its `dependencies/blocked_by` list or its `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh-axi issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: `gh-axi issue comment <n> --body "<answer>"`, then `gh-axi issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
