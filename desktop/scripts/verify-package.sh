#!/usr/bin/env bash
# 校验 cargo-packager 产物「结构上可安装」。CI 与本地共用。
# 未签名产物是预期状态（证书暂无，签名/公证归 epic-6），这里只记录不失败。
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
shopt -s nullglob

for f in dist/*.dmg; do
  echo "== dmg: $f"
  hdiutil verify "$f" >/dev/null
  echo "   hdiutil verify ok"
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

echo "package verification passed（unsigned builds are expected until epic-6）"
