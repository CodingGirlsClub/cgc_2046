#!/usr/bin/env bash
# CI sentinel for the merge decision (fail-closed):
#   - block until the PR's checks settle (sleep loop, bounded by MAX_WAIT)
#   - all green            -> exit 0 (clear to merge)
#   - only known flake red -> rerun failed jobs (bounded), keep waiting
#   - any other real fail  -> print failing job names + failed log lines, exit 1
#   - no checks ever show up / wait exceeded -> exit 2
# Zero third-party deps: bash + git + gh-axi (the repo's gh passthrough).
#
# Usage: ci-sentinel.sh <pr-number> [head-branch]
#   head-branch defaults to the current git branch (run from the worktree).
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <pr-number> [head-branch]" >&2
  exit 2
fi
pr="$1"
branch="${2:-$(git branch --show-current)}"
[ -n "$branch" ] || { echo "[sentinel] no head branch (pass it explicitly)" >&2; exit 2; }

interval=60          # seconds between polls
max_wait=3600        # give up after this many seconds overall
max_reruns=2         # known-flake rerun budget
reruns=0
waited=0

ghx() { npx -y gh-axi "$@"; }

# Extract "N passed/failed/skipped/total" from: summary: "6 passed, 0 failed, 1 skipped, 7 total"
sum_field() { printf '%s' "$1" | sed -n "s/.*\([0-9][0-9]*\) $2.*/\1/p"; }

while :; do
  out="$(ghx pr checks "$pr" 2>/dev/null)" || {
    echo "[sentinel] gh-axi pr checks $pr failed" >&2; exit 1;
  }
  summary="$(printf '%s\n' "$out" | sed -n 's/^summary: "\(.*\)"$/\1/p')"
  if [ -z "$summary" ]; then
    echo "[sentinel] no checks reported for PR $pr yet — sleeping ${interval}s" >&2
  else
    passed="$(sum_field "$summary" passed)";  passed="${passed:-0}"
    failed="$(sum_field "$summary" failed)";  failed="${failed:-0}"
    skipped="$(sum_field "$summary" skipped)"; skipped="${skipped:-0}"
    total="$(sum_field "$summary" total)";    total="${total:-0}"

    if [ "$failed" -eq 0 ]; then
      if [ "$total" -gt 0 ] && [ $((passed + skipped)) -ge "$total" ]; then
        echo "[sentinel] PR $pr checks settled: $summary — clear to merge"
        exit 0
      fi
      echo "[sentinel] pending ($summary) — sleeping ${interval}s"
    else
      # checks rows look like: "  <name>,<conclusion>" with conclusion pass|skip|fail|pending
      failing="$(printf '%s\n' "$out" | awk -F, '/^[[:space:]]*[^[:space:]][^,]*,(pass|skip|fail|pending)$/ && $2=="fail" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1}')"
      echo "[sentinel] failing jobs: $(printf '%s' "$failing" | tr '\n' ' ')" >&2

      if [ "$(printf '%s' "$failing" | tr -d '[:space:]')" = "ext" ]; then
        # sole known single-point flake — bounded rerun
        if [ "$reruns" -ge "$max_reruns" ]; then
          echo "[sentinel] ext still red after $reruns reruns — treat as real, exiting" >&2
          exit 1
        fi
        reruns=$((reruns + 1))
        run_id="$(ghx run list --branch "$branch" --limit 1 2>/dev/null | awk -F, '/^[[:space:]]*[0-9][0-9]*,/ {gsub(/^[[:space:]]+/, "", $1); print $1; exit}')"
        [ -n "$run_id" ] || { echo "[sentinel] cannot resolve CI run id for branch '$branch'" >&2; exit 1; }
        echo "[sentinel] ext-only flake (rerun $reruns/$max_reruns) -> gh-axi run rerun $run_id --failed" >&2
        ghx run rerun "$run_id" --failed >&2 || { echo "[sentinel] rerun request failed" >&2; exit 1; }
      else
        # real failure — fail-closed: print failing job + its failed log lines
        run_id="$(ghx run list --branch "$branch" --limit 1 2>/dev/null | awk -F, '/^[[:space:]]*[0-9][0-9]*,/ {gsub(/^[[:space:]]+/, "", $1); print $1; exit}')"
        if [ -n "$run_id" ]; then
          echo "[sentinel] failed log (run $run_id, tail):" >&2
          ghx run view "$run_id" --log-failed 2>/dev/null | tail -n 20 >&2
        fi
        echo "[sentinel] real failure on PR $pr — stopping, orchestrator must triage" >&2
        exit 1
      fi
    fi
  fi

  sleep "$interval"
  waited=$((waited + interval))
  if [ "$waited" -ge "$max_wait" ]; then
    echo "[sentinel] exceeded max wait ${max_wait}s for PR $pr" >&2
    exit 2
  fi
done
