#!/usr/bin/env bash
# New-worktree bootstrap: installs dependencies so a fresh checkout is
# ready to develop. Idempotent — safe to re-run.
#
# Wire this into your worktree tooling (e.g. Orca project settings → setup
# hook). The database is a shared local Postgres instance (see
# backend/config/dev.exs) — it is created once per machine with
# `cd backend && mix setup`, not per worktree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }

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
