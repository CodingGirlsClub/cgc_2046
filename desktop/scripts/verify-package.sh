#!/usr/bin/env bash
# 校验 cargo-packager 产物「结构上可安装」。CI 与本地共用。
# 未签名产物是预期状态（证书暂无，签名/公证归 epic-6）：这里记录真实签名状态，不因未签名失败。
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
shopt -s nullglob

for f in dist/*.dmg; do
  echo "== dmg: $f"
  base=$(basename "$f")
  if ! [[ "$base" =~ ^cgc2046_[0-9]+\.[0-9]+\.[0-9]+_[0-9a-f]{7,}_[a-z0-9]+\.dmg$ ]]; then
    echo "FAIL: 产物名缺版本/commit（期望 cgc2046_<version>_<commit>_<arch>.dmg，实际 $base）" >&2
    exit 1
  fi
  echo "   name ok: $base"
  hdiutil verify "$f" >/dev/null
  echo "   hdiutil verify ok"

  if codesign -dv "$f" >/dev/null 2>&1; then
    echo "   signature: signed"
  else
    echo "   signature: unsigned（预期，epic-6 接管签名）"
  fi

  mnt=$(mktemp -d "${TMPDIR:-/tmp}/cgc-dmg.XXXXXX")
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$f" >/dev/null
  app=$(ls -d "$mnt"/*.app 2>/dev/null | head -1)
  test -n "$app" || { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; echo "FAIL: dmg 内没有 .app" >&2; exit 1; }
  echo "   app bundle ok: $(basename "$app")"
  test -e "$mnt/Applications" || { hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; echo "FAIL: dmg 内缺 Applications 链接" >&2; exit 1; }
  echo "   Applications link ok"
  hdiutil detach "$mnt" -force >/dev/null
  rmdir "$mnt" 2>/dev/null || true
  found=1
done

for f in dist/*.deb; do
  echo "== deb: $f"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -c "$f" >/dev/null
    echo "   dpkg-deb -c ok"
  else
    echo "   dpkg-deb 不可用（非 Debian 系宿主），跳过结构校验"
  fi
  found=1
done

for f in dist/*.AppImage; do
  echo "== AppImage: $f"
  rm -rf squashfs-root
  "$f" --appimage-extract >/dev/null
  test -x squashfs-root/AppRun
  echo "   --appimage-extract ok"
  rm -rf squashfs-root
  found=1
done

if [ "$found" -eq 0 ]; then
  echo "FAIL: desktop/dist 下没有任何已知安装包产物" >&2
  exit 1
fi

echo "package verification passed"
