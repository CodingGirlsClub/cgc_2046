#!/usr/bin/env bash
# 安装包重命名：cgc2046_<version>_<commit>_<platform>-<arch>.<ext>（story 1.7/1.13 同源命名）。
# 版本取 Cargo 包版本（与 build.rs 的 CGC_BUILD_VERSION 同源），commit 取 git short SHA
# （CI 可用 CGC_BUILD_COMMIT 覆盖，保持与关于页一致）。
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(cargo metadata --no-deps --format-version 1 2>/dev/null \
  | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="cgc-desktop-app"))')
commit="${CGC_BUILD_COMMIT:-$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)}"
# 架构段：macOS universal 包由 CI 用 CGC_ARTIFACT_ARCH=universal 指定；
# 其余平台回落到本机架构（打包器只在对应平台跑）。
arch="${CGC_ARTIFACT_ARCH:-$(uname -m)}"
if [ -z "${CGC_ARTIFACT_ARCH:-}" ]; then
  case "$arch" in
    x86_64|amd64) arch=x64 ;;
    arm64|aarch64) arch=aarch64 ;;
  esac
fi

shopt -s nullglob
renamed=0
for f in dist/*; do
  base=$(basename "$f")
  case "$base" in
    *.dmg|*.msi|*.deb|*.AppImage|*.exe) ;;
    *) continue ;;
  esac
  ext="${base##*.}"
  # 平台段让用户只看文件名就知道该下哪个包（.msi/.deb/.dmg 不是所有人都认识）。
  case "$ext" in
    dmg) platform=macos ;;
    msi|exe) platform=windows ;;
    deb|AppImage) platform=linux ;;
  esac
  target="dist/cgc2046_${version}_${commit}_${platform}-${arch}.${ext}"
  if [ "$f" != "$target" ]; then
    mv -f "$f" "$target"
    echo "renamed: $base -> $(basename "$target")"
    renamed=$((renamed+1))
  fi
done

if [ "$renamed" -eq 0 ]; then
  echo "no artifact to rename (dist empty or already named)"
else
  echo "artifact name: cgc2046_${version}_${commit}_<platform>-${arch}.<ext>"
fi
