#!/usr/bin/env bash
# New-worktree bootstrap: links the ignored agent config, copies the ignored
# backend/.env and installs dependencies so a fresh checkout is ready to
# develop. Idempotent — safe to re-run.
#
# Run it right after creating a worktree, whatever created it. Creating the
# worktree's own database (`PASEO_BRANCH_NAME` suffix, see
# backend/config/dev.exs) stays with the caller: it runs `cd backend && mix setup`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }

# --- agent config: .agents/ is ignored, so a worktree starts without it ---
# `.agents/skills` holds the project skills; only some are tracked, the rest
# exist only in the primary checkout (ignored via .git/info/exclude). Agents
# discover skills at `<projectRoot>/.agents/skills` with no fallback to the
# primary checkout, so
# skip this link and a worktree session silently loses those skills.
# Mirror it into a real `.agents/` directory: the ignore pattern is `.agents/`,
# which matches a directory but not a symlink — a symlinked `.agents` would sit
# in `git status` as untracked forever.
if GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  PRIMARY_ROOT="$(dirname "$(cd "$GIT_COMMON_DIR" && pwd -P)")"
  if [ "$PRIMARY_ROOT" = "$REPO_ROOT" ]; then
    log "Primary checkout — .agents/skills already in place."
  elif [ -d "$PRIMARY_ROOT/.agents/skills" ]; then
    # Link skill by skill: some skills are tracked (already checked out here),
    # the rest exist only in the primary checkout.
    mkdir -p .agents/skills
    for src in "$PRIMARY_ROOT"/.agents/skills/*/; do
      [ -d "$src" ] || continue
      name="$(basename "$src")"
      if [ -e ".agents/skills/$name" ] || [ -L ".agents/skills/$name" ]; then
        continue
      fi
      if [ -f "$src/.loopx-managed-project-skill.json" ]; then
        # LoopX-managed skills only work in the connected primary checkout:
        # LoopX rejects symlinked copies and needs .loopx/registry.json.
        log "Skipped LoopX-managed skill $name (used from the primary checkout)."
        continue
      fi
      ln -s "${src%/}" ".agents/skills/$name"
      log "Linked .agents/skills/$name"
    done
  else
    warn "No .agents/skills in $PRIMARY_ROOT — project skills stay unavailable here."
  fi

  # backend/.env is ignored too: copy the primary checkout's file (never print it).
  if [ "$PRIMARY_ROOT" != "$REPO_ROOT" ] && [ ! -e backend/.env ] && [ -f "$PRIMARY_ROOT/backend/.env" ]; then
    cp "$PRIMARY_ROOT/backend/.env" backend/.env
    log "Copied backend/.env from $PRIMARY_ROOT."
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

# --- miniprogram (Taro + pnpm) ---
if [ -f miniprogram/package.json ]; then
  log "Installing miniprogram dependencies (pnpm install --frozen-lockfile)..."
  if command -v pnpm >/dev/null 2>&1; then
    (cd miniprogram && pnpm install --frozen-lockfile)
  else
    warn "pnpm not found — run 'cd miniprogram && pnpm install' manually."
  fi
fi

log "Worktree setup complete."
