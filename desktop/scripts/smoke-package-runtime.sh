#!/usr/bin/env bash
# macOS 专用：从 dist/*.dmg 挂载 .app，启动 release 二进制并确认存活 5s，
# 记录 RSS。用于人工/真机验收时的「安装包可运行」检查（不进 CI：runner 无 WindowServer）。
# 用法：bash scripts/smoke-package-runtime.sh [seconds]
set -euo pipefail
cd "$(dirname "$0")/.."

dmg=$(ls dist/*.dmg 2>/dev/null | head -1 || true)
[ -n "$dmg" ] || { echo "FAIL: dist 下没有 dmg" >&2; exit 1; }
seconds=${1:-5}
mnt=$(mktemp -d "${TMPDIR:-/tmp}/cgc-runtime.XXXXXX")
app_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cgc-app.XXXXXX")
cleanup() {
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
  rm -rf "$mnt" "$app_tmp"
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
app=$(ls -d "$mnt"/*.app | head -1)
[ -n "$app" ] || { echo "FAIL: dmg 内没有 .app" >&2; exit 1; }
cp -R "$app" "$app_tmp/CGC.app"
bin="$app_tmp/CGC.app/Contents/MacOS/cgc-desktop-app"
[ -x "$bin" ] || { echo "FAIL: 缺少可执行文件" >&2; exit 1; }

CGC_AUTH=fake CGC_THEME=dark CGC_LANG=zh CGC_START_PATH=/events \
  CGC_SESSION_FILE="$app_tmp/session.json" "$bin" >"$app_tmp/run.log" 2>&1 &
pid=$!
sleep "$seconds"
if ! kill -0 "$pid" 2>/dev/null; then
  echo "FAIL: 打包二进制提前退出" >&2
  cat "$app_tmp/run.log" >&2
  exit 1
fi
echo "runtime ok: $(basename "$dmg")"
ps -o pid,rss,%cpu,etime,comm -p "$pid" | tail -1
