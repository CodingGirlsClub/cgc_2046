#!/usr/bin/env bash
# New-worktree bootstrap: links the ignored agent config and installs
# dependencies so a fresh checkout is ready to develop. Idempotent — safe to
# re-run.
#
# Wire this into your worktree tooling (e.g. paseo.json worktree.setup, or Orca
# project settings → setup hook). Creating the worktree's own database
# (`PASEO_BRANCH_NAME` suffix, see backend/config/dev.exs) stays with the
# caller: it runs `cd backend && mix setup`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }

# --- agent config: .agents/ is ignored, so a worktree starts without it ---
# `.agents/skills` holds the project skills and exists only in the primary
# checkout (ignored via .git/info/exclude). Agents discover skills at
# `<projectRoot>/.agents/skills` with no fallback to the primary checkout, so
# skip this link and a worktree session silently loses those skills.
# Mirror it into a real `.agents/` directory: the ignore pattern is `.agents/`,
# which matches a directory but not a symlink — a symlinked `.agents` would sit
# in `git status` as untracked forever.
if GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  PRIMARY_ROOT="$(dirname "$(cd "$GIT_COMMON_DIR" && pwd -P)")"
  if [ "$PRIMARY_ROOT" = "$REPO_ROOT" ]; then
    log "Primary checkout — .agents/skills already in place."
  elif [ -e .agents/skills ] || [ -L .agents/skills ]; then
    log ".agents/skills already linked — leaving it as is."
  elif [ -d "$PRIMARY_ROOT/.agents/skills" ]; then
    mkdir -p .agents
    ln -s "$PRIMARY_ROOT/.agents/skills" .agents/skills
    log "Linked .agents/skills -> $PRIMARY_ROOT/.agents/skills"
  else
    warn "No .agents/skills in $PRIMARY_ROOT — project skills stay unavailable here."
  fi
fi

# --- web (Next.js + pnpm workspace) ---
if [ -f web/package.json ]; then
  log "Installing web dependencies (pnpm install --frozen-lockfile)..."
  if command -v pnpm >/dev/null 2>&1; then
    (cd web && pnpm install --frozen-lockfile)
  else
    warn "pnpm not found — run 'cd web && pnpm install' manually."
  fi
fi

# --- backend (Elixir / Phoenix) ---
if [ -f backend/mix.exs ]; then
  log "Fetching backend dependencies (mix deps.get)..."
  if command -v mix >/dev/null 2>&1; then
    (cd backend && mix deps.get)
  else
    warn "mix not found — run 'cd backend && mix deps.get' manually."
  fi
fi

log "Worktree setup complete."
