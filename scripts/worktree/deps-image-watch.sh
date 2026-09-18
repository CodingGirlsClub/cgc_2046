#!/bin/bash
# 盯 develop 最新 run 的 deps-image job（mix.lock 变更后的发布前置门）。
# 每轮重新取 develop 最新 run——合并顶掉旧 run 时自动跟随，无需重启。
# 用法: deps-image-watch.sh
# 2026-09-18 入库自 /tmp（/tmp 被系统清理导致监控断档），cd 硬编码改为脚本相对推导。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

export PATH="$HOME/.local/share/mise/installs/node/latest/bin:$PATH"
export XDG_CACHE_HOME="${TMPDIR:-/tmp}/gh-cache"

for i in $(seq 1 150); do
  rid=$(gh run list --branch develop --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
  st=$(gh run view "$rid" --json jobs --jq '.jobs[] | select(.name=="deps-image") | "\(.status)/\(.conclusion // "-")"' 2>/dev/null)
  echo "[$i $(date +%H:%M:%S)] run=$rid deps-image=$st"
  case "$st" in
    completed/success) echo "=== deps-image 绿，可发布"; exit 0;;
    completed/failure|cancelled)
      echo "=== deps-image 未成功：$st"
      jid=$(gh run view "$rid" --json jobs --jq '.jobs[] | select(.name=="deps-image") | .databaseId' 2>/dev/null)
      timeout 120 gh run view --job "$jid" --log-failed 2>/dev/null | tail -20 | cut -c1-200
      exit 1;;
    completed/skipped) echo "=== deps-image skipped（可能命中已有镜像），继续看 backend"; exit 0;;
  esac
  sleep 60
done
echo "=== 超时"
