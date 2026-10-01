#!/usr/bin/env bash
# 纯文档判定（CI changes job 用，#1051）：stdin 逐行读变更文件路径，
# 全部落在白名单（docs/** 或仓库根 *.md）时输出 docs_only=true，否则 false。
# fail-closed：空输入、任何非白名单路径都判 false（全量跑 CI）。
# case 里 * 会匹配 /，所以含 / 的路径必须在 *.md 之前先排除，
# 否则 web/README.md 之类会被误当根目录文档。
set -u
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$((n + 1))
  case "$f" in
    docs/*) ;;
    */*) echo "docs_only=false"; exit 0 ;;
    *.md) ;;
    *) echo "docs_only=false"; exit 0 ;;
  esac
done
[ "$n" -gt 0 ] && echo "docs_only=true" || echo "docs_only=false"
