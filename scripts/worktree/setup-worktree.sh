#!/usr/bin/env bash
# New-worktree bootstrap: links the ignored agent config, copies the ignored
# backend/.env, installs dependencies and — in a linked worktree — creates the
# worktree's own database, so a fresh checkout is ready to develop.
# Idempotent — safe to re-run. Run it right after creating a worktree,
# whatever created it; it needs nothing else to wire it up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }

# --- agent config: .agents/ is ignored, so a worktree starts without it ---
# `.agents/skills` holds the project skills; only some are tracked, the rest
# exist only in the primary checkout (ignored via .git/info/exclude). Agents
# discover skills at `<projectRoot>/.agents/skills` with no fallback to the
# primary checkout, so skip these links and a worktree session silently loses
# those skills. Mirror them into a real `.agents/` directory: the ignore
# pattern is `.agents/`, which matches a directory but not a symlink — a
# symlinked `.agents` would sit in `git status` as untracked forever.
LINKED_WORKTREE=false
if GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  PRIMARY_ROOT="$(dirname "$(cd "$GIT_COMMON_DIR" && pwd -P)")"
  if [ "$PRIMARY_ROOT" != "$REPO_ROOT" ]; then
    LINKED_WORKTREE=true
  fi
  if [ "$LINKED_WORKTREE" = false ]; then
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
  if [ "$LINKED_WORKTREE" = true ] && [ ! -e backend/.env ] && [ -f "$PRIMARY_ROOT/backend/.env" ]; then
    if cp "$PRIMARY_ROOT/backend/.env" backend/.env; then
      log "Copied backend/.env from $PRIMARY_ROOT."
    else
      warn "Could not copy backend/.env from $PRIMARY_ROOT — copy it manually."
    fi
  fi
fi

# --- 本地推送门禁：push 前自动跑 backend format 检查（scripts/githooks/pre-push）---
# 安装到共享 hooks 目录：.git 对所有 worktree 共用，不随分支切换消失；
# 源码版本化在 scripts/githooks/，.git/hooks 本身不入库不受全局 ignore 影响。
if [ -f scripts/githooks/pre-push ]; then
  common_dir="$(git rev-parse --git-common-dir)"
  common_dir="$(cd "$common_dir" && pwd)"
  install -m 0755 scripts/githooks/pre-push "$common_dir/hooks/pre-push"
  log "Installed pre-push gate -> $common_dir/hooks/pre-push."
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
# In a linked worktree `mix setup` also creates and seeds the worktree's own
# database (name suffix: backend/config/worktree_suffix.exs; needs Postgres).
# The primary checkout only fetches deps: its shared dev database is left alone.
if [ -f backend/mix.exs ]; then
  if ! command -v mix >/dev/null 2>&1; then
    warn "mix not found — run 'cd backend && mix setup' manually."
  elif [ "$LINKED_WORKTREE" = true ]; then
    # Fail safe: without a suffix `mix setup` would migrate and seed the shared
    # dev database with this branch's unmerged migrations.
    suffix="$(cd backend && elixir -e '{s, _} = Code.eval_file("config/worktree_suffix.exs"); IO.write(s)' 2>/dev/null || true)"
    if [ -z "$suffix" ]; then
      warn "Could not derive this worktree's database suffix — skipped mix setup to leave the shared dev database alone."
      (cd backend && mix deps.get)
    else
      log "Setting up backend dependencies and database cgc_2046_dev$suffix (mix setup)..."
      (cd backend && mix setup) || warn "mix setup failed (is Postgres running?) — rerun 'cd backend && mix setup'."
    fi
  else
    log "Fetching backend dependencies (mix deps.get)..."
    (cd backend && mix deps.get)
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
