/**
 * backend-format-gate.ts — project-level omp hook (extension module).
 *
 * Guards `git commit` / `git push` against unformatted Elixir code:
 * when the bash tool is about to run a git commit/push and there are
 * staged or unstaged changes under backend/*.ex / *.exs (recursive), it runs
 * `mix format --check-formatted` first. If formatting fails, the git
 * command is blocked with the offending file list, so CI never trips on
 * `mix format --check-formatted`.
 *
 * Loaded from <repo>/.omp/extensions/ (project-level native auto-discovery).
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const BACKEND = "backend";

function isGitCommitish(cmd) {
  // git commit ... / git push ... / git -c ... commit / git pull --rebase (no)
  if (!/\bgit\b/.test(cmd)) return false;
  if (/\bgit\s+(-[a-zA-Z]+\s+)*commit\b/.test(cmd)) return true;
  if (/\bgit\s+(-[a-zA-Z]+\s+)*push\b/.test(cmd)) return true;
  return false;
}

function hasElixirChanges(cwd) {
  try {
    const out = execFileSync("git", ["status", "--porcelain", "--", `${BACKEND}/**/*.ex`, `${BACKEND}/**/*.exs`], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 15_000,
    });
    return out.trim().length > 0;
  } catch {
    // git status failed (not a repo, no backend dir) -> don't block
    return false;
  }
}

function checkBackendFormat(cwd) {
  const mixDir = join(cwd, BACKEND);
  if (!existsSync(join(mixDir, "mix.exs"))) return { ok: true, detail: "no backend/mix.exs" };
  try {
    execFileSync("mix", ["format", "--check-formatted"], {
      cwd: mixDir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
    });
    return { ok: true, detail: "mix format --check-formatted OK" };
  } catch (err) {
    const msg = err?.stderr || err?.message || "";
    return { ok: false, detail: msg.trim().slice(0, 2000) };
  }
}

export default function backendFormatGate(pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const cmd = String(event.input?.command ?? "");
    if (!isGitCommitish(cmd)) return;

    const cwd = ctx?.cwd || process.cwd();
    if (!hasElixirChanges(cwd)) return; // no backend changes -> let it pass

    const res = checkBackendFormat(cwd);
    if (res.ok) return; // formatted -> pass

    return {
      block: true,
      reason:
        `backend format gate: mix format --check-formatted FAILED before git ${cmd.split(/\s+/)[1] ?? "commit"}.\n` +
        `Fix formatting first (cd backend && mix format), then retry.\n---\n${res.detail}`,
    };
  });
}
