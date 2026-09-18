#!/bin/bash
# 分支哨兵：盯 develop / main 的 push run —— 出现失败立即打印详情并退出（触发编排侧通知）
# 用法: branch-sentinel.sh [label]
# 与 ci-sentinel 的区别：ci-sentinel 盯 PR checks；本哨兵盯「合并后 develop/main 自己红」，
# 这正是 2026-09-17 漏掉过一次的场景（#695 合并后 develop backend 红 20 分钟无人发现）。
# 2026-09-18 入库自 /tmp（/tmp 被系统清理导致监控断档），cd 硬编码改为脚本相对推导。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

export PATH="$HOME/.local/share/mise/installs/node/latest/bin:$PATH"
LABEL="${1:-develop/main}"
SEEN="${TMPDIR:-/tmp}/branch-sentinel-seen.txt"
touch "$SEEN"

echo "=== 分支哨兵启动 [$LABEL] $(date +%H:%M:%S)（每 60s 查 develop/main 最近 run）"
for i in $(seq 1 480); do
  for br in develop main; do
    rid=$(gh run list --branch "$br" --limit 1 --json databaseId,conclusion,status \
      --jq '.[0] | select(.conclusion=="failure") | .databaseId' 2>/dev/null)
    [ -z "$rid" ] && continue
    grep -qx "$rid" "$SEEN" && continue
    echo "$rid" >> "$SEEN"
    info=$(gh run list --branch "$br" --limit 1 --json databaseId,displayTitle,createdAt,url --jq '.[0] | "\(.databaseId) \(.displayTitle[0:60]) \(.createdAt) \(.url)"' 2>/dev/null)
    echo "=== [$LABEL] ❌ $br 分支 run 失败：$info"
    echo "--- 失败 job:"
    gh run view "$rid" --json jobs --jq '.jobs[] | select(.conclusion=="failure") | "  \(.name)"' 2>/dev/null
    jid=$(gh run view "$rid" --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .databaseId' 2>/dev/null | head -1)
    echo "--- 失败步骤日志尾（$jid）:"
    timeout 120 gh run view --job "$jid" --log-failed 2>/dev/null | tail -25 | cut -c1-220
    exit 1
  done
  sleep 60
done
echo "=== [$LABEL] 分支哨兵超时退出（8 小时无失败）"
