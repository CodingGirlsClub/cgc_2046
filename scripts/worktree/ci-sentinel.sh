#!/usr/bin/env bash
# CI sentinel for the merge decision (fail-closed), with auto update-branch /
# auto merge / known-flake rerun:
#   merged               -> 已合并 ✓, exit 0
#   behind               -> update-branch, then settle >=90s before re-polling
#   dirty                -> GitHub 判冲突, update branch 无用 -> exit 1 (按 SOP §4 重建)
#   checks not ready     -> keep waiting — empty summary, empty fail list, or
#                           "no CI checks" wording are all treated as NOT RED:
#                           right after update-branch the checks list is
#                           briefly empty while the new run registers (race we
#                           actually hit; never judge red from an empty list)
#   all green            -> merge (merge commit), exit 0
#   only known flake red -> rerun failed jobs (bounded), keep waiting
#   other real fail      -> print failing job names + failed log lines, exit 1
#   wait exceeded        -> exit 2
# Zero third-party deps: bash + git + gh-axi (the repo's gh passthrough).
#
# Usage: ci-sentinel.sh <pr-number> [label]
#   label is a log prefix only; the head branch is taken from the PR API.
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <pr-number> [label]" >&2
  exit 2
fi
pr="$1"
label="${2:-PR #$pr}"

interval=60          # seconds between polls
settle=90            # fixed settle after update-branch (new-run registration)
max_wait=7200        # give up after this many seconds overall
max_reruns=2         # known-flake rerun budget
reruns=0
waited=0

ghx() { npx -y gh-axi "$@"; }
say() { printf '=== [%s] %s\n' "$label" "$*"; }
sub() { printf '  [%s] %s\n' "$label" "$*" >&2; }

# state, merged, mergeable_state, head.ref — one API call per poll.
# gh-axi wraps the body as:   body: "open,false,behind,refs/..."  — unwrap it.
pr_meta() {
  ghx api "repos/{owner}/{repo}/pulls/$pr" --jq '[.state,.merged,.mergeable_state,.head.ref]|join(",")' 2>/dev/null \
    | sed -n 's/^  body: "\(.*\)"$/\1/p'
}
# Extract "N passed/failed/skipped/total" from: summary: "6 passed, 0 failed, 1 skipped, 7 total"
sum_field() { printf '%s' "$1" | sed -n "s/.*\([0-9][0-9]*\) $2.*/\1/p"; }

while :; do
  meta="$(pr_meta)"
  if [ -n "$meta" ]; then
    IFS=',' read -r p_state p_merged p_ms p_head <<< "$meta"
    if [ "$p_state" = "closed" ] && [ "$p_merged" = "true" ]; then
      say "已合并 ✓ — 无事可做"
      exit 0
    fi
    if [ "$p_ms" = "behind" ]; then
      sub "BEHIND → update-branch"
      if ! ghx pr update-branch "$pr" >&2; then
        say "update-branch 失败 — 编排者介入"
        exit 1
      fi
      sub "settle ${settle}s（新 run 注册前 checks 为空属正常空窗，不当红）"
      sleep "$settle"
      waited=$((waited + settle))
      continue
    fi
    if [ "$p_ms" = "dirty" ]; then
      say "DIRTY：GitHub 判冲突，update branch 救不了 → 按 SOP §4 重建"
      exit 1
    fi
  fi

  out="$(ghx pr checks "$pr" 2>/dev/null)" || {
    sub "pr checks 调用失败 — ${interval}s 后重试"
    sleep "$interval"; waited=$((waited + interval))
    if [ "$waited" -ge "$max_wait" ]; then say "超过 max_wait ${max_wait}s"; exit 2; fi
    continue
  }
  summary="$(printf '%s\n' "$out" | sed -n 's/^summary: "\(.*\)"$/\1/p')"

  # Not ready — keep waiting, never red: empty summary, or "no CI checks" wording
  if [ -z "$summary" ] || printf '%s\n' "$out" | grep -qi 'no CI checks'; then
    sub "checks 未就绪（summary 空 / no CI checks）— 继续等"
    sleep "$interval"; waited=$((waited + interval))
    if [ "$waited" -ge "$max_wait" ]; then say "超过 max_wait ${max_wait}s"; exit 2; fi
    continue
  fi

  passed="$(sum_field "$summary" passed)";  passed="${passed:-0}"
  failed="$(sum_field "$summary" failed)";  failed="${failed:-0}"
  skipped="$(sum_field "$summary" skipped)"; skipped="${skipped:-0}"
  total="$(sum_field "$summary" total)";    total="${total:-0}"

  if [ "$failed" -eq 0 ]; then
    if [ "$total" -gt 0 ] && [ $((passed + skipped)) -ge "$total" ]; then
      say "checks 全绿（$summary）→ merge（merge commit）"
      if ghx pr merge "$pr" --merge; then
        say "已合并 ✓"
        exit 0
      fi
      say "merge 失败 — 编排者介入"
      exit 1
    fi
    sub "pending（$summary）— ${interval}s"
  else
    # checks rows look like: "  <name>,<conclusion>" with conclusion pass|skip|fail|pending
    failing="$(printf '%s\n' "$out" | awk -F, '/^[[:space:]]*[^[:space:]][^,]*,(pass|skip|fail|pending)$/ && $2=="fail" {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1}')"
    # Empty fail list while failed>0 -> checks still settling, NOT red (race guard)
    if [ -z "$failing" ]; then
      sub "failed=$failed 但失败列表为空，视为未就绪 — 继续等"
      sleep "$interval"; waited=$((waited + interval))
      if [ "$waited" -ge "$max_wait" ]; then say "超过 max_wait ${max_wait}s"; exit 2; fi
      continue
    fi
    sub "CI 红：$(printf '%s' "$failing" | tr '\n' ' ')"

    if [ "$(printf '%s' "$failing" | tr -d '[:space:]')" = "ext" ]; then
      if [ "$reruns" -ge "$max_reruns" ]; then
        say "ext 重跑 $reruns 次仍红 — 按真实失败处理"
        exit 1
      fi
      reruns=$((reruns + 1))
      run_id="$(ghx run list --branch "$p_head" --limit 1 2>/dev/null | awk -F, '/^[[:space:]]*[0-9][0-9]*,/ {gsub(/^[[:space:]]+/, "", $1); print $1; exit}')"
      [ -n "$run_id" ] || { say "取不到分支 '$p_head' 的 CI run id"; exit 1; }
      sub "ext 单点 flake（rerun $reruns/$max_reruns）→ run rerun $run_id --failed"
      ghx run rerun "$run_id" --failed >&2 || { say "rerun 请求失败"; exit 1; }
      sleep "$settle"; waited=$((waited + settle))
      continue
    fi

    run_id="$(ghx run list --branch "$p_head" --limit 1 2>/dev/null | awk -F, '/^[[:space:]]*[0-9][0-9]*,/ {gsub(/^[[:space:]]+/, "", $1); print $1; exit}')"
    if [ -n "$run_id" ]; then
      sub "失败日志（run $run_id，尾部）："
      ghx run view "$run_id" --log-failed 2>/dev/null | tail -n 20 >&2
    fi
    say "真实失败 — fail-closed，编排者介入"
    exit 1
  fi

  sleep "$interval"
  waited=$((waited + interval))
  if [ "$waited" -ge "$max_wait" ]; then
    say "超过 max_wait ${max_wait}s（PR $pr）"
    exit 2
  fi
done
