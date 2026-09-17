#!/usr/bin/env bash
# Watch a worktree agent without interrupting it: block until the agent goes
# idle, then print how to collect its report. Wraps `paseo wait` so the
# orchestrator never busy-polls a running agent. Zero third-party deps.
#
# Usage: watch-idle.sh <agent-id> [timeout-seconds]
#   <agent-id> accepts the full id or the shortId prefix shown by `paseo ls`.
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <agent-id> [timeout-seconds]" >&2
  exit 2
fi
agent_id="$1"

# Agent status from `paseo ls --json` (pretty-printed; match the id/shortId
# line, then the status line inside the same object). `paseo inspect` reports
# "Agent not found" with exit 0 and has no top-level status, so it is useless
# as a gate here.
agent_status() {
  paseo ls --json 2>/dev/null | awk -v id="$agent_id" '
    index($0, "\"id\": \"" id) || index($0, "\"shortId\": \"" id) { inblk = 1 }
    inblk && /"status":/ { line = $0; sub(/.*"status": *"/, "", line); sub(/".*/, "", line); print line; exit }
  '
}

status="$(agent_status)"
if [ -z "$status" ]; then
  echo "[watch] agent '$agent_id' not found in paseo ls" >&2
  exit 1
fi

wait_args=()
if [ $# -ge 2 ]; then
  wait_args=(--timeout "$2")
fi
wait_out="$(paseo wait "$agent_id" "${wait_args[@]}" 2>&1)"
# `paseo wait` exits 0 even on timeout or unknown-agent — inspect its output.
if printf '%s' "$wait_out" | grep -q 'did not finish within'; then
  echo "[watch] still not idle after timeout — run me again with a longer [timeout-seconds]" >&2
  exit 1
fi

# Final gate: confirm idle rather than trusting wait's exit code.
status="$(agent_status)"
if [ "$status" = "idle" ]; then
  echo "[watch] '$agent_id' is idle — collect the report now:"
  echo "        paseo logs $agent_id | tail -n 40"
else
  echo "[watch] '$agent_id' stopped in status '${status:-unknown}', not idle — inspect before trusting any report" >&2
  exit 1
fi
