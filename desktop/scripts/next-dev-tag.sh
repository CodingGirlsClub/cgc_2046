#!/usr/bin/env bash
# 生成下一个内测 tag：desktop-v<base>-dev.<YYYYMMDD>.<当天序号>
#
# 为什么按天 + 序号（ADR-0027 内测通道）：内测包一天可能发多次，若用固定版本号，
# 每次都要改 desktop/Cargo.toml 并提交，且无法区分同一天的两个包。判据与 #1183 的
# schema 门禁同源——tag 是发布身份，Cargo.toml 只承载 base 版本（0.1.0）。
#
# 用法：
#   git fetch --tags origin           # 先同步远端 tag，否则当天序号会算错
#   tag=$(bash scripts/next-dev-tag.sh)
#   git tag -a "$tag" origin/develop -m "CGC-2046 桌面客户端内测"
#   git push origin "$tag"
set -euo pipefail
cd "$(dirname "$0")/.."

base=$(python3 - <<'PY'
import pathlib, re
text = pathlib.Path("Cargo.toml").read_text()
match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
print(match.group(1) if match else "")
PY
)
[ -n "$base" ] || { echo "FAIL: 读不到 Cargo.toml 的 base 版本" >&2; exit 1; }

# UTC 日期：CI runner 与本地时区不同，用 UTC 才能让「当天」二字有唯一含义。
day=$(date -u +%Y%m%d)
prefix="desktop-v${base}-dev.${day}"

# 数当天已有的 tag（含不带序号的旧形态，也计入，避免重号）。
existing=$(git tag -l "${prefix}*" | wc -l | tr -d ' ')
next=$((existing + 1))

echo "${prefix}.${next}"
